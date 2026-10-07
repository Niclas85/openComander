import Foundation
import CryptoKit
import Darwin

/// Remote audit entries are not local filesystem undo records. Persist only
/// human-readable locations, never credentials or temporary download URLs.
struct CloudOperationRecord: Codable, Equatable {
    let action: String
    let source: String
    let destination: String
    var createdAt = Date()
}

enum OperationType: Codable {
    case delete(files: [FileUndoRecord])
    case move(files: [FileUndoRecord])
    case copy(files: [FileUndoRecord])
    case zip(record: FileUndoRecord)
    case rename(record: FileUndoRecord)
    case cloud(record: CloudOperationRecord)
}

/// Desktop selection rules mirror the Linux context menu and ZIP toolbar.
enum DesktopInteractionPolicy {
    static func contextSelection(clicked: String, selected: Set<String>) -> Set<String> {
        selected.contains(clicked) ? selected : [clicked]
    }

    static func showsExtraction(archiveContext: Bool, selectedArchives: [Bool]) -> Bool {
        archiveContext || (!selectedArchives.isEmpty && selectedArchives.allSatisfy { $0 })
    }
}

/// Reject unsafe/ambiguous ZIP names before creating any output. Limits match
/// the Linux desktop implementation and also apply to preview materialization.
struct SafeArchiveLimits {
    static let maximumEntries = 100_000
    static let maximumBytes: UInt64 = 4 * 1024 * 1024 * 1024
    private var paths = Set<String>()
    private var bytes: UInt64 = 0

    mutating func include(path: String, size: UInt64, symbolicLink: Bool) throws {
        let name = path.hasSuffix("/") ? String(path.dropLast()) : path
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard !symbolicLink, !name.isEmpty, !name.hasPrefix("/"),
              !name.contains("\\"), !name.contains("\0"),
              !parts.contains(".."), !parts.contains("."), !parts.contains(""),
              !(parts.first?.contains(":") ?? false),
              paths.count < Self.maximumEntries, size <= Self.maximumBytes - bytes,
              paths.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted else {
            throw NSError(domain: "OpenCommander.ZIP", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: L10n.get("extract_unsafe")])
        }
        bytes += size
    }
}

enum BoundedFolderSize {
    static func bytes(at root: URL, timeout: TimeInterval = 10, maximumEntries: Int = 100_000) throws -> Int64 {
        let deadline = Date().addingTimeInterval(timeout)
        var total: Int64 = 0
        var count = 0
        var enumerationError: Error?
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let items = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
            errorHandler: { _, error in enumerationError = error; return false }) else {
            throw CocoaError(.fileReadNoPermission)
        }
        for case let url as URL in items {
            count += 1
            guard count <= maximumEntries, Date() < deadline else { throw CocoaError(.userCancelled) }
            let values = try url.resourceValues(forKeys: keys)
            // DirectoryEnumerator does not descend through symlinks. Calling
            // skipDescendants on a leaf can instead skip the next real directory.
            if values.isSymbolicLink == true { continue }
            if values.isRegularFile == true { total += Int64(values.fileSize ?? 0) }
        }
        if let enumerationError { throw enumerationError }
        return total
    }
}

/// Thread-safe cooperative cancellation. Partial copies exist only in staging.
final class FileOperationCancellation {
    private let lock = NSLock()
    private var requested = false
    func reset() { lock.lock(); requested = false; lock.unlock() }
    func cancel() { lock.lock(); requested = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return requested }
    func check() throws { if isCancelled { throw CocoaError(.userCancelled) } }

    func copy(_ source: URL, _ destination: URL) throws {
        try check()
#if os(macOS) || targetEnvironment(macCatalyst)
        guard let state = copyfile_state_alloc() else { throw POSIXError(.ENOMEM) }
        defer { copyfile_state_free(state) }
        let callback: copyfile_callback_t = { _, _, _, _, _, context in
            guard let context else { return COPYFILE_QUIT }
            return Unmanaged<FileOperationCancellation>.fromOpaque(context).takeUnretainedValue().isCancelled ? COPYFILE_QUIT : COPYFILE_CONTINUE
        }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(self).toOpaque())
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW_SRC | COPYFILE_EXCL)
        guard copyfile(source.path, destination.path, state, flags) == 0 else {
            try check()
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
#else
        try FileManager.default.copyItem(at: source, to: destination)
#endif
        try check()
    }
}

/// File operations kept separate from UIKit so failure paths can be tested with fixtures.
enum SafeFileOperations {
    static func exists(_ url: URL) -> Bool {
        // Includes dangling symlinks: these are still occupied destination names.
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    static func conflict(_ url: URL) -> NSError {
        NSError(domain: "OpenCommander.FileSafety", code: 1,
                userInfo: [NSLocalizedDescriptionKey: L10n.get("undo_changed") + "\n" + url.path])
    }

    static func snapshot(_ url: URL) throws -> Data {
        let fm = FileManager.default
        var digest = SHA256()
        func field(_ string: String) {
            let data = Data(string.utf8)
            digest.update(data: Data("\(data.count):".utf8))
            digest.update(data: data)
        }
        func visit(_ item: URL) throws {
            let attributes = try fm.attributesOfItem(atPath: item.path)
            guard let type = attributes[.type] as? FileAttributeType else { throw conflict(item) }
            field(item.lastPathComponent)
            field(type.rawValue)
            field(String(describing: attributes[.systemFileNumber]))
            field(String((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0))
            for key in [FileAttributeKey.posixPermissions, .ownerAccountID, .groupOwnerAccountID] {
                field(String(describing: attributes[key]))
            }
            if type == .typeDirectory {
                let children = try fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                field(String(children.count))
                for child in children { try visit(child) }
            } else if type == .typeSymbolicLink {
                field(try fm.destinationOfSymbolicLink(atPath: item.path))
            } else if type == .typeRegular {
                var content = SHA256()
                let handle = try FileHandle(forReadingFrom: item)
                defer { try? handle.close() }
                while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
                    content.update(data: data)
                }
                digest.update(data: Data(content.finalize()))
            } else {
                throw conflict(item)
            }
        }
        try visit(url)
        return Data(digest.finalize())
    }

    /// Finish copying before displacing the old target. Staging is on the target volume.
    static func copyReplacing(source: URL, destination: URL, replace: Bool,
                              copy: (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) },
                              publish: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }) throws -> URL? {
        let fm = FileManager.default
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".OpenCommanderTransfer-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        let payload = staging.appendingPathComponent("payload")
        let backup = staging.appendingPathComponent("previous")
        var displaced = false
        var keepRecovery = false
        defer {
            if !keepRecovery { try? fm.removeItem(at: staging) }
        }
        do {
            try copy(source, payload)
            if exists(destination) {
                guard replace else { throw conflict(destination) }
                try fm.moveItem(at: destination, to: backup)
                displaced = true
            }
            try publish(payload, destination)
            keepRecovery = displaced
            return displaced ? backup : nil
        } catch {
            if displaced {
                // Never remove an unexpected destination just to restore the previous file.
                do {
                    guard !exists(destination) else { throw conflict(destination) }
                    try fm.moveItem(at: backup, to: destination)
                } catch let recoveryError {
                    keepRecovery = true
                    throw NSError(domain: "OpenCommander.FileSafety", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey:
                                    L10n.get("recovery_retained", staging.path) + "\n" + recoveryError.localizedDescription,
                                             NSUnderlyingErrorKey: error])
                }
            }
            throw error
        }
    }
}

final class FileUndoRecord: Codable {
    let createdAt: Date
    let source: URL
    let destination: URL
    let replacedBackup: URL?
    private let snapshot: Data?
    private var destinationReverted = false
    private(set) var completed = false
    var lastError: String?

    init(source: URL, destination: URL, replacedBackup: URL?) {
        createdAt = Date()
        self.source = source
        self.destination = destination
        self.replacedBackup = replacedBackup
        // A read failure disables undo; it must never roll back an already completed move.
        snapshot = try? SafeFileOperations.snapshot(destination)
    }

    func undo(move: Bool) throws {
        if completed { return }
        let fm = FileManager.default
        if !destinationReverted {
            guard let snapshot, snapshot == (try SafeFileOperations.snapshot(destination)) else {
                throw SafeFileOperations.conflict(destination)
            }
            if move {
                guard !SafeFileOperations.exists(source) else { throw SafeFileOperations.conflict(source) }
                try fm.moveItem(at: destination, to: source)
            } else {
                // Retain the current version even if an external writer raced the snapshot.
                let recovery = destination.deletingLastPathComponent()
                    .appendingPathComponent(".OpenCommanderUndo-\(UUID().uuidString)", isDirectory: true)
                try fm.createDirectory(at: recovery, withIntermediateDirectories: false)
                try fm.moveItem(at: destination, to: recovery.appendingPathComponent(destination.lastPathComponent))
            }
            destinationReverted = true
        }
        if let backup = replacedBackup {
            guard !SafeFileOperations.exists(destination) else { throw SafeFileOperations.conflict(destination) }
            try fm.moveItem(at: backup, to: destination)
        }
        completed = true
    }
}
