import Foundation
import CryptoKit

/// Connection settings contain no passwords. Paths are absolute and never shell commands.
struct RemoteConnection: Codable, Equatable {
    var id = UUID().uuidString
    var name: String
    var scheme: String
    var host: String
    var port: Int
    var user: String
    var root: String
    var keyPath: String
    var trustedHostKeys: String? = nil
    var passwordAuthentication: Bool? = nil
    var tlsCAPath: String? = nil
    var locationPath: String { "remote://" + id }
    var displayAddress: String { "\(scheme)://\(user)@\(host):\(port)\(root)" }
    static let defaultsKey = "remote_connections_v1"
    static func load() -> [RemoteConnection] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([Self].self, from: data)) ?? []
    }
    static func save(_ values: [Self]) throws {
        UserDefaults.standard.set(try JSONEncoder().encode(values), forKey: defaultsKey)
    }
    func validate() throws {
        guard UUID(uuidString: id) != nil, ["ftp", "ftps", "sftp"].contains(scheme), (1...65535).contains(port),
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !host.isEmpty, host.range(of: "^[A-Za-z0-9.:-]+$", options: .regularExpression) != nil,
              !host.hasPrefix("-"), !user.isEmpty,
              user.range(of: "^[A-Za-z0-9_.@-]+$", options: .regularExpression) != nil,
              !user.hasPrefix("-"), Self.validPath(root),
              keyPath.isEmpty || Self.validPath(keyPath),
              tlsCAPath == nil || Self.validPath(tlsCAPath!) else { throw Self.failure("remote_invalid") }
    }
    static func fingerprints(_ keys: String) throws -> String {
        var result: [String] = []
        for line in keys.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            let parts = line.split(separator: " ")
            guard parts.count == 3, ["ssh-ed25519", "ecdsa-sha2-nistp256", "ssh-rsa"].contains(String(parts[1])),
                  let bytes = Data(base64Encoded: String(parts[2])), bytes.count > 16 else { throw failure("remote_invalid") }
            result.append(String(parts[1]) + " SHA256:" + Data(SHA256.hash(data: bytes)).base64EncodedString().replacingOccurrences(of: "=", with: ""))
        }
        guard !result.isEmpty else { throw failure("remote_ssh_failed") }
        return result.joined(separator: "\n")
    }
    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name.utf8.count <= 255 &&
        !name.contains(where: { $0 == "/" || $0 == "\\" || $0.asciiValue.map { $0 < 32 || $0 == 127 } == true })
    }
    static func validPath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains(where: { $0 == "\\" || $0.asciiValue.map { $0 < 32 || $0 == 127 } == true }) &&
        !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }
    func contains(_ path: String) -> Bool {
        let base = root == "/" ? "/" : root.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return Self.validPath(path) && (root == "/" || path == "/" + base || path.hasPrefix("/" + base + "/"))
    }
    static func failure(_ key: String) -> NSError {
        NSError(domain: "OpenCommander.Remote", code: 1, userInfo: [NSLocalizedDescriptionKey: key])
    }
}

struct RemoteDirectoryItem: Codable {
    var name: String
    var directory: Bool
    var size: Int64
    var modified: String
    var unsafe: Bool = false
    var version: String { "\(directory):\(size):\(modified)" }

    /// RFC 3659 MLSD avoids locale-dependent FTP LIST parsing. Never follow links.
    static func mlsd(_ listing: String) throws -> [Self] {
        var result: [Self] = []
        for raw in listing.components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if line.isEmpty { continue }
            guard let separator = line.firstIndex(of: " ") else { throw RemoteConnection.failure("remote_listing") }
            let name = String(line[line.index(after: separator)...])
            var facts: [String: String] = [:]
            for pair in line[..<separator].split(separator: ";") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                if parts.count == 2 { facts[String(parts[0]).lowercased()] = String(parts[1]) }
            }
            let type = facts["type"]?.lowercased()
            if type == "cdir" || type == "pdir" { continue }
            guard RemoteConnection.validName(name) else { throw RemoteConnection.failure("remote_listing") }
            result.append(Self(name: name, directory: type == "dir", size: Int64(facts["size"] ?? "0") ?? 0,
                               modified: facts["modify"] ?? "", unsafe: type != "dir" && type != "file"))
            guard result.count <= 100_000 else { throw RemoteConnection.failure("remote_limit") }
        }
        return result
    }

    static func sftp(_ listing: String) throws -> [Self] {
        let pattern = try NSRegularExpression(pattern: "^([d-][rwxStTs-]{9})\\s+[0-9?]+\\s+\\S+\\s+\\S+\\s+(\\d+)\\s+(\\S+\\s+\\d+\\s+\\S+)\\s(.+)$")
        var result: [Self] = []
        for line in listing.components(separatedBy: .newlines) where !line.isEmpty {
            if line.hasPrefix("sftp> ") || line.hasPrefix("total ") { continue }
            if line.hasPrefix("l") {
                // Preserve presence for collision checks, but never navigate or materialize links.
                result.append(Self(name: "", directory: false, size: 0, modified: "", unsafe: true)); continue
            }
            guard let match = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
                throw RemoteConnection.failure("remote_listing")
            }
            func part(_ i: Int) -> String { String(line[Range(match.range(at: i), in: line)!]) }
            let raw = part(4), name = (raw as NSString).lastPathComponent
            if name == "." || name == ".." { continue }
            guard RemoteConnection.validName(name) else { throw RemoteConnection.failure("remote_listing") }
            result.append(Self(name: name, directory: part(1).hasPrefix("d"), size: Int64(part(2)) ?? 0, modified: part(3)))
            guard result.count <= 100_000 else { throw RemoteConnection.failure("remote_limit") }
        }
        return result
    }
}

enum RemoteContent {
    static func snapshotAsync(_ root: URL, hidden: Bool = true) async throws -> [String: String] {
        let worker = Task.detached { try snapshot(root, hidden: hidden) }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
    /// Content-only manifest, independent of local inode numbers or remote IDs.
    static func snapshot(_ root: URL, hidden: Bool = true) throws -> [String: String] {
        var result: [String: String] = [:]
        func visit(_ url: URL, relative: String, depth: Int) throws {
            try Task.checkCancellation()
            guard depth < 100, result.count < 100_000 else { throw RemoteConnection.failure("remote_limit") }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw RemoteConnection.failure("remote_listing") }
            if values.isDirectory == true {
                result[relative] = "directory"
                for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                    if !hidden && child.lastPathComponent.hasPrefix(".") { continue }
                    guard RemoteConnection.validName(child.lastPathComponent) else { throw RemoteConnection.failure("remote_invalid") }
                    try visit(child, relative: relative.isEmpty ? child.lastPathComponent : relative + "/" + child.lastPathComponent, depth: depth + 1)
                }
            } else {
                guard values.isRegularFile == true else { throw RemoteConnection.failure("remote_listing") }
                let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
                var digest = SHA256()
                while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty { try Task.checkCancellation(); digest.update(data: data) }
                result[relative] = "sha256:" + Data(digest.finalize()).base64EncodedString()
            }
        }
        try visit(root, relative: "", depth: 0); return result
    }
}
