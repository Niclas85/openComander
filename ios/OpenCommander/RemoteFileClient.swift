#if targetEnvironment(macCatalyst) || os(macOS)
import Foundation
import CryptoKit

/// FTP/FTPS and OpenSSH SFTP share the existing embedded browser and transfer workflows.
@MainActor final class RemoteFileClient: CommanderOnlineClient {
    let profile: RemoteConnection
    var clientID: String { "remote:" + profile.id }
    private(set) var moveBackupLocation: String?
    var transferProgress: ((String, Int64, Int64) -> Void)?
    private static var pathRegistries: [String: [String: String]] = [:]
    private var paths: [String: String] {
        get { Self.pathRegistries[profile.id] ?? [:] }
        set { Self.pathRegistries[profile.id] = newValue }
    }
    private let passwords = OneDriveKeychain() // separate service account namespace
    typealias Transport = (String, Data, String?, String, String, String?, URL?, @escaping (Data?, NSError?) -> Void) -> Void
    private let transport: Transport
    private let cancelTransport: (String) -> Void
    private let passwordProvider: (() throws -> String?)?
    init(_ profile: RemoteConnection, transport: Transport? = nil, cancel: ((String) -> Void)? = nil,
         password: (() throws -> String?)? = nil) {
        self.profile = profile; passwordProvider = password
#if targetEnvironment(macCatalyst)
        self.transport = transport ?? { id, connection, password, operation, path, destination, local, completion in
            guard let bridge = DesktopBridge.shared else { completion(nil, RemoteConnection.failure("remote_unavailable")); return }
            bridge.remoteOperation(id, connection: connection, password: password, operation: operation, path: path,
                                  destination: destination, localURL: local, completion: completion)
        }
        cancelTransport = cancel ?? { DesktopBridge.shared?.cancelRemoteOperation($0) }
#else
        self.transport = transport ?? { _, _, _, _, _, _, _, completion in completion(nil, RemoteConnection.failure("remote_unavailable")) }
        cancelTransport = cancel ?? { _ in }
#endif
        paths["root:" + profile.id] = profile.root
    }
    private func path(_ id: String?) throws -> String {
        guard let value = id == nil ? profile.root : paths[id!], profile.contains(value) else { throw RemoteConnection.failure("remote_invalid") }
        return value
    }
    private func identifier(_ path: String) -> String {
        if let existing = paths.first(where: { $0.value == path })?.key { return existing }
        let id = UUID().uuidString; paths[id] = path; return id
    }
    private func childPath(_ parent: String, _ name: String) throws -> String {
        guard RemoteConnection.validName(name) else { throw RemoteConnection.failure("remote_invalid") }
        return parent == "/" ? "/" + name : parent.trimmingCharacters(in: CharacterSet(charactersIn: "/")).withLeadingSlash + "/" + name
    }
    private func perform(_ operation: String, _ path: String, destination: String? = nil, local: URL? = nil) async throws -> Data {
        try Task.checkCancellation(); try profile.validate()
        let data = try JSONEncoder().encode(profile), requestID = UUID().uuidString
        let password = profile.scheme == "sftp" && profile.passwordAuthentication != true ? nil : try (passwordProvider?() ?? passwords.read(clientID: clientID))
        let cancel = cancelTransport
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                transport(requestID, data, password, operation, path, destination, local) { reply, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: reply ?? Data()) }
                }
            }
        }, onCancel: { cancel(requestID) })
    }
    private func measuredDownload(_ path: String, local: URL, size: Int64, phase: String) async throws {
        transferProgress?(phase, 0, size)
        let monitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let count = (try? local.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                // 100% is reserved for the caller's completed integrity check.
                self?.transferProgress?(phase, min(count, max(0, size - 1)), size)
                do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
            }
        }
        defer { monitor.cancel() }
        _ = try await perform("download", path, local: local)
    }
    func children(of id: String?) async throws -> [OneDriveItem] {
        try await directoryItems(path(id))
    }
    private func directoryItems(_ parent: String, rejectUnsafe: Bool = false) async throws -> [OneDriveItem] {
        let listing = try JSONDecoder().decode([RemoteDirectoryItem].self, from: await perform("list", parent))
        if rejectUnsafe && listing.contains(where: \.unsafe) { throw RemoteConnection.failure("remote_listing") }
        return try listing.filter { !$0.unsafe }.map { entry in
            let itemPath = try childPath(parent, entry.name)
            return OneDriveItem(id: identifier(itemPath), name: entry.name, size: entry.size,
                folder: entry.directory ? .init(childCount: nil) : nil, lastModifiedDateTime: entry.modified,
                eTag: entry.version, parentReference: .init(id: identifier(parent)))
        }
    }
    func toolChildren(of id: String?) async throws -> [OneDriveItem] {
        try await directoryItems(path(id), rejectUnsafe: true)
    }
    func metadata(_ id: String?) async throws -> OneDriveItem {
        let value = try path(id)
        if value == profile.root {
            return OneDriveItem(id: identifier(value), name: profile.name, size: nil, folder: .init(childCount: nil),
                lastModifiedDateTime: nil, eTag: "root", root: [:])
        }
        let parent = (value as NSString).deletingLastPathComponent
        guard let item = try await children(of: identifier(parent)).first(where: { $0.id == id }) else { throw RemoteConnection.failure("remote_missing") }
        return item
    }
    private func vacant(_ name: String, parent: String?) async throws {
        guard RemoteConnection.validName(name) else { throw RemoteConnection.failure("remote_invalid") }
        let listing = try JSONDecoder().decode([RemoteDirectoryItem].self, from: await perform("list", path(parent)))
        guard !listing.contains(where: \.unsafe) else { throw RemoteConnection.failure("remote_listing") }
        guard !listing.contains(where: { OneDriveConflictNames.key($0.name) == OneDriveConflictNames.key(name) }) else { throw OneDriveFailure.nameConflict }
    }
    func createFolder(_ name: String, parent: String?) async throws {
        try await vacant(name, parent: parent)
        _ = try await perform("mkdir", childPath(path(parent), name))
    }
    func validateDestination(_ parent: String?, excluding itemID: String) async throws {
        let destination = try path(parent), source = try path(itemID)
        guard destination != source, !destination.hasPrefix(source + "/") else { throw RemoteConnection.failure("remote_cycle") }
    }
    func rename(_ item: OneDriveItem, to name: String) async throws {
        let parent = identifier((try path(item.id) as NSString).deletingLastPathComponent)
        try await move(item, parent: parent, name: name)
    }
    func move(_ item: OneDriveItem, parent: String?, name: String? = nil) async throws {
        let source = try path(item.id), targetName = name ?? item.name
        try await validateDestination(parent, excluding: item.id)
        try await vacant(targetName, parent: parent)
        guard try await metadata(item.id).eTag == item.eTag else { throw RemoteConnection.failure("remote_changed") }
        let target = try childPath(path(parent), targetName)
        _ = try await perform("rename", source, destination: target)
        for (id, old) in paths where old == source || old.hasPrefix(source + "/") {
            paths[id] = target + String(old.dropFirst(source.count))
        }
    }
    func recycle(_ item: OneDriveItem) async throws {
        guard try await metadata(item.id).eTag == item.eTag else { throw RemoteConnection.failure("remote_changed") }
        // Nonempty directories are deliberately not removed recursively.
        _ = try await perform(item.isFolder ? "rmdir" : "delete", path(item.id))
    }
    func remoteSnapshot(_ item: OneDriveItem) async throws -> [String: String] {
        let url = try await downloadTree(item)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return try await Task.detached { try RemoteContent.snapshot(url) }.value
    }
    func recycleUnchanged(_ item: OneDriveItem, snapshot: [String: String]) async throws {
        moveBackupLocation = nil
        guard !snapshot.isEmpty, try await remoteSnapshot(item) == snapshot else { throw RemoteConnection.failure("remote_changed") }
        let original = try path(item.id), parent = (original as NSString).deletingLastPathComponent
        let backup = try childPath(parent, ".OpenCommander-Recovery-" + UUID().uuidString)
        _ = try await perform("rename", original, destination: backup)
        func relocate(_ from: String, _ to: String) {
            for (id, old) in paths where old == from || old.hasPrefix(from + "/") { paths[id] = to + String(old.dropFirst(from.count)) }
        }
        relocate(original, backup)
        do {
            let archived = try await metadata(item.id)
            guard try await remoteSnapshot(archived) == snapshot else { throw RemoteConnection.failure("remote_changed") }
        } catch {
            let verificationError = error
            // Preserve both copies on any uncertainty. Roll back only into a vacant original name.
            do {
                try await vacant(item.name, parent: identifier(parent))
                _ = try await perform("rename", backup, destination: original); relocate(backup, original)
            } catch { moveBackupLocation = profile.displayAddress + " → " + backup }
            throw verificationError
        }
        // Never permanently delete an unversioned source. The original name is gone,
        // but a recovery copy remains on the source server, even for whole folders.
        moveBackupLocation = profile.scheme + "://" + profile.host + ":\(profile.port)" + backup
    }
    func upload(_ url: URL, parent: String?) async throws {
        try await vacant(url.lastPathComponent, parent: parent)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw RemoteConnection.failure("remote_invalid") }
        let base = try path(parent), temporary = try childPath(base, ".opencommander-" + UUID().uuidString)
        _ = try await perform("upload", temporary, local: url)
        // Read back before reporting success or allowing local source removal.
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("OpenCommander-Verify-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        let expectedSize = Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        try await measuredDownload(temporary, local: staging, size: expectedSize, phase: "remote_verify_phase")
        let original = try await Task.detached { try Self.hash(url) }.value
        let uploaded = try await Task.detached { try Self.hash(staging) }.value
        guard original == uploaded else { throw RemoteConnection.failure("remote_changed") }
        transferProgress?("remote_verify_phase", expectedSize, expectedSize)
        try await vacant(url.lastPathComponent, parent: parent)
        _ = try await perform("rename", temporary, destination: childPath(base, url.lastPathComponent))
    }
    nonisolated private static func hash(_ url: URL) throws -> Data {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty { try Task.checkCancellation(); hash.update(data: data) }
        return Data(hash.finalize())
    }
    func uploadTree(_ url: URL, parent: String?) async throws {
        _ = try await Task.detached { try OneDriveClient.localSnapshot(url) }.value
        func visit(_ url: URL, parent: String?, depth: Int) async throws {
            try Task.checkCancellation()
            guard depth < 100 else { throw RemoteConnection.failure("remote_limit") }
            if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                try await createFolder(url.lastPathComponent, parent: parent)
                let folder = identifier(try childPath(path(parent), url.lastPathComponent))
                for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) { try await visit(child, parent: folder, depth: depth + 1) }
            } else { try await upload(url, parent: parent) }
        }
        try await visit(url, parent: parent, depth: 0)
    }
    func download(_ item: OneDriveItem) async throws -> URL {
        guard !item.isFolder, RemoteConnection.validName(item.name) else { throw RemoteConnection.failure("remote_invalid") }
        let current = try await metadata(item.id)
        guard current.name == item.name, !current.isFolder else { throw RemoteConnection.failure("remote_changed") }
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("OpenCommander-Remote-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false)
        let file = container.appendingPathComponent(item.name)
        do {
            try await measuredDownload(path(item.id), local: file, size: current.size ?? 0, phase: "remote_download_phase")
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard Int64(size ?? -1) == current.size, try await metadata(item.id).eTag == current.eTag else { throw RemoteConnection.failure("remote_changed") }
            transferProgress?("remote_download_phase", current.size ?? 0, current.size ?? 0)
            return file
        } catch { try? FileManager.default.removeItem(at: container); throw error }
    }
    func downloadTree(_ item: OneDriveItem) async throws -> URL {
        if !item.isFolder { return try await download(item) }
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("OpenCommander-Remote-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false)
        let root = container.appendingPathComponent(item.name)
        var count = 0
        func visit(_ item: OneDriveItem, _ url: URL, _ depth: Int) async throws {
            count += 1; try Task.checkCancellation()
            guard depth < 100, count < 100_000, RemoteConnection.validName(item.name) else { throw RemoteConnection.failure("remote_limit") }
            if item.isFolder {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                for child in try await directoryItems(path(item.id), rejectUnsafe: true) { try await visit(child, url.appendingPathComponent(child.name), depth + 1) }
            } else {
                let source = try await download(item); defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
                try FileManager.default.moveItem(at: source, to: url)
            }
        }
        do { try await visit(item, root, 0); return root }
        catch { try? FileManager.default.removeItem(at: container); throw error }
    }
    func hasSavedLogin() throws -> Bool { true }
    func beginLogin() async throws -> OneDriveDeviceCode { throw RemoteConnection.failure("remote_invalid") }
    func completeLogin(_ code: OneDriveDeviceCode) async throws { throw RemoteConnection.failure("remote_invalid") }
    func disconnect() throws { }
}
private extension String { var withLeadingSlash: String { "/" + self } }

/// Shared, bounded tools for OneDrive and direct server connections.
@MainActor enum CommanderOnlineTools {
    struct Entry { let item: OneDriveItem; let ancestors: [OneDriveItem]; let path: String }
    struct Rename { let item: OneDriveItem; let name: String }
    static func resolve(_ path: String, client: any CommanderOnlineClient) async throws -> [OneDriveItem] {
        guard path.hasPrefix("/"), !path.contains("\0"), !path.split(separator: "/").contains("..") else { throw RemoteConnection.failure("remote_invalid") }
        var result: [OneDriveItem] = []
        for name in path.split(separator: "/") {
            try Task.checkCancellation()
            guard result.count < 100, let item = try await client.children(of: result.last?.id).first(where: { $0.name == name && $0.isFolder }) else { throw RemoteConnection.failure("remote_missing") }
            result.append(item)
        }
        return result
    }
    static func scan(_ client: any CommanderOnlineClient, ancestors: [OneDriveItem], hidden: Bool,
                     progress: (Int) -> Void = { _ in }) async throws -> [Entry] {
        var entries: [Entry] = [], seen = Set<String>()
        func visit(_ parents: [OneDriveItem], relative: String, depth: Int) async throws {
            try Task.checkCancellation()
            guard depth < 100 else { throw RemoteConnection.failure("remote_limit") }
            for item in try await client.toolChildren(of: parents.last?.id) {
                try Task.checkCancellation()
                if !hidden && item.name.hasPrefix(".") { continue }
                guard entries.count < 100_000, seen.insert(item.id).inserted else { throw RemoteConnection.failure("remote_limit") }
                let path = relative.isEmpty ? item.name : relative + "/" + item.name
                entries.append(.init(item: item, ancestors: parents, path: path)); progress(entries.count)
                if item.isFolder { try await visit(parents + [item], relative: path, depth: depth + 1) }
            }
        }
        try await visit(ancestors, relative: "", depth: 0); return entries
    }
    static func matches(_ name: String, query: String, caseSensitive: Bool) throws -> Bool {
        let query = query.precomposedStringWithCanonicalMapping
        let glob = query.contains("*") || query.contains("?")
        let pattern = NSRegularExpression.escapedPattern(for: query).replacingOccurrences(of: "\\*", with: ".*").replacingOccurrences(of: "\\?", with: ".")
        let regex = try NSRegularExpression(pattern: glob ? "^" + pattern + "$" : pattern, options: caseSensitive ? [] : .caseInsensitive)
        let name = name.precomposedStringWithCanonicalMapping
        return regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }
    static func content(_ client: any CommanderOnlineClient, ancestors: [OneDriveItem], hidden: Bool,
                        progress: (Int, Int) -> Void = { _, _ in }) async throws -> [String: String] {
        let entries = try await scan(client, ancestors: ancestors, hidden: hidden)
        var result: [String: String] = [:]
        for (index, entry) in entries.enumerated() {
            try Task.checkCancellation()
            if entry.item.isFolder { result[entry.path] = "directory" }
            else {
                let url = try await client.download(entry.item)
                defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                result[entry.path] = try await RemoteContent.snapshotAsync(url)[""]!
            }
            progress(index + 1, entries.count)
        }
        let after = try await scan(client, ancestors: ancestors, hidden: hidden)
        func versions(_ entries: [Entry]) -> [String: String] {
            Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0.item.id + "|" + ($0.item.eTag ?? "")) })
        }
        guard versions(entries) == versions(after) else { throw RemoteConnection.failure("remote_changed") }
        return result
    }
    static func renamePlan(_ client: any CommanderOnlineClient, parent: String?, selected: [OneDriveItem], fields: [String]) async throws -> [Rename] {
        guard fields.count == 5, !selected.isEmpty, selected.count <= 10_000,
              let start = Int(fields[3]), start >= 0, start <= Int.max - selected.count,
              let digits = Int(fields[4]), (1...9).contains(digits) else { throw RemoteConnection.failure("remote_invalid") }
        let siblings = try await client.children(of: parent)
        let tokens = try NSRegularExpression(pattern: "\\[(N|E|C)\\]")
        var seen = Set<String>(), plan: [Rename] = []
        for (index, item) in selected.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }).enumerated() {
            try Task.checkCancellation()
            guard let current = siblings.first(where: { $0.id == item.id }), current.eTag != nil, current.name == item.name, current.eTag == item.eTag else { throw RemoteConnection.failure("remote_changed") }
            let url = URL(fileURLWithPath: item.name), ext = item.isFolder ? "" : url.pathExtension
            let stem = ext.isEmpty ? item.name : url.deletingPathExtension().lastPathComponent
            var name = fields[0]
            for match in tokens.matches(in: fields[0], range: NSRange(fields[0].startIndex..., in: fields[0])).reversed() {
                let token = (fields[0] as NSString).substring(with: match.range)
                let value = token == "[N]" ? stem : token == "[E]" ? (ext.isEmpty ? "" : "." + ext) : String(format: "%0*d", digits, start + index)
                name = (name as NSString).replacingCharacters(in: match.range, with: value)
            }
            if !fields[1].isEmpty { name = name.replacingOccurrences(of: fields[1], with: fields[2]) }
            guard OneDriveClient.validName(name), RemoteConnection.validName(name), seen.insert(OneDriveConflictNames.key(name)).inserted,
                  !siblings.contains(where: { $0.id != item.id && OneDriveConflictNames.key($0.name) == OneDriveConflictNames.key(name) }),
                  name == item.name || OneDriveConflictNames.key(name) != OneDriveConflictNames.key(item.name) else { throw OneDriveFailure.nameConflict }
            plan.append(.init(item: current, name: name))
        }
        return plan
    }
    static func rename(_ client: any CommanderOnlineClient, plan: [Rename], didRename: (Rename) async -> Void) async throws -> Int {
        for row in plan {
            let current = try await client.metadata(row.item.id)
            guard current.name == row.item.name, current.eTag == row.item.eTag else { throw RemoteConnection.failure("remote_changed") }
        }
        var count = 0
        for row in plan where row.name != row.item.name {
            try Task.checkCancellation(); try await client.rename(row.item, to: row.name)
            count += 1; await didRename(row)
        }
        return count
    }
}
#endif
