import Foundation
import Security
import CryptoKit

struct OneDriveItem: Decodable {
    struct Folder: Decodable { let childCount: Int? }
    struct ParentReference: Decodable { let id: String? }
    let id: String
    let name: String
    let size: Int64?
    let folder: Folder?
    let lastModifiedDateTime: String?
    let eTag: String?
    var parentReference: ParentReference? = nil
    var root: [String: String]? = nil
    var cTag: String? = nil
    var isFolder: Bool { folder != nil }
}

struct OneDriveDeviceCode: Decodable {
    let device_code: String
    let user_code: String
    let verification_uri: String
    let expires_in: Int
    let interval: Int?
}

enum OneDriveFailure: LocalizedError {
    case message(String)
    case nameConflict
    var errorDescription: String? {
        if case .message(let text) = self { return text }
        let german = (UserDefaults.standard.string(forKey: "language") ?? Locale.current.language.languageCode?.identifier ?? "en").hasPrefix("de")
        return german ? "Am OneDrive-Ziel ist bereits ein Element mit diesem Namen vorhanden. Die vorhandene Datei wurde nicht ersetzt. Aktualisiere den Ordner und wähle beim Kopieren ‚Beide behalten‘ oder ‚Überspringen‘. Bei Ordnern können bereits kopierte Teile vorhanden sein."
            : "An item with this name already exists in OneDrive. The existing file was not replaced. Refresh the folder and choose Keep Both or Skip when copying. A folder transfer may already have copied some items."
    }
}

enum OneDriveConflictNames {
    static func key(_ name: String) -> String {
        name.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).precomposedStringWithCanonicalMapping
    }
    static func available(_ name: String, folder: Bool, existing: [String]) -> String {
        let names = Set(existing.map(key))
        guard names.contains(key(name)) else { return name }
        let ext = folder ? "" : (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var index = 2
        while true {
            let number = " (\(index))"
            let suffix = number + (ext.isEmpty ? "" : "." + ext)
            // An unusually long extension may itself occupy the entire name
            // budget. In that case number the bounded whole name instead.
            let candidate = suffix.count >= 255
                ? String(name.prefix(255 - number.count)) + number
                : String(stem.prefix(255 - suffix.count)) + suffix
            if !names.contains(key(candidate)) { return candidate }
            index += 1
        }
    }
}

protocol OneDriveTokenStore {
    func read(clientID: String) throws -> String?
    func write(_ token: String?, clientID: String) throws
}

private final class OneDriveRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        let allowed = OneDriveClient.allowedRedirect(from: task.originalRequest?.url, to: request.url)
        completionHandler(allowed ? request : nil)
    }
}

struct OneDriveKeychain: OneDriveTokenStore {
    private func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "OpenCommander.OneDrive",
         kSecAttrAccount as String: id]
    }
    func read(clientID: String) throws -> String? {
        var q = query(clientID)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw OneDriveFailure.message("OneDrive: Keychain error (\(status)).")
        }
        return value
    }
    func write(_ token: String?, clientID: String) throws {
        let q = query(clientID)
        guard let token else {
            let status = SecItemDelete(q as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw OneDriveFailure.message("OneDrive: Keychain error (\(status)).")
            }
            return
        }
        let data = Data(token.utf8)
        var status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insertion = q
            insertion[kSecValueData as String] = data
            insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(insertion as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw OneDriveFailure.message("OneDrive: Keychain error (\(status)).") }
    }
}

/// Public-client OAuth. No browser cookies, passwords or client secrets are read.
/// Refresh credentials stay in Keychain; Graph bearer tokens are sent only to graph.microsoft.com.
@MainActor final class OneDriveClient {
    let clientID: String
    private let session: URLSession
    private let store: OneDriveTokenStore
    private let downloadFile: (URL) async throws -> (URL, URLResponse)
    private var accessToken: String?
    private var expiresAt = Date.distantPast
    private let authority = "https://login.microsoftonline.com/common/oauth2/v2.0/"
    private let graph = "https://graph.microsoft.com/v1.0"
    private let scopes = "Files.ReadWrite offline_access"
    private struct Tokens: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int
    }
    private struct OAuthError: Decodable { let error: String; let error_description: String? }
    private struct Page: Decodable {
        let value: [OneDriveItem]
        let next: String?
        enum CodingKeys: String, CodingKey { case value; case next = "@odata.nextLink" }
    }

    init(clientID: String, session: URLSession? = nil, store: OneDriveTokenStore = OneDriveKeychain(),
         downloadFile: ((URL) async throws -> (URL, URLResponse))? = nil) {
        self.clientID = clientID; self.store = store
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.timeoutIntervalForRequest = 60
            self.session = URLSession(configuration: configuration, delegate: OneDriveRedirectGuard(), delegateQueue: nil)
        }
        let transport = self.session
        self.downloadFile = downloadFile ?? { try await transport.download(from: $0) }
    }
    nonisolated static func allowedRedirect(from source: URL?, to destination: URL?) -> Bool {
        guard let source, let destination, destination.scheme == "https",
              destination.user == nil, destination.password == nil else { return false }
        if source.host == "graph.microsoft.com" || source.host == "login.microsoftonline.com" {
            return destination.host == source.host && destination.port == source.port
        }
        return true // Preauthenticated content downloads carry no bearer token or OAuth body.
    }
    static func validClientID(_ value: String) -> Bool { UUID(uuidString: value) != nil }
    nonisolated static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name.count <= 255 &&
        !name.contains(where: { "\\/:*?\"<>|".contains($0) || $0.isNewline || $0.asciiValue.map { $0 < 32 } == true }) &&
        !name.hasSuffix(".") && !name.hasSuffix(" ")
    }
    private func form(_ values: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return Data(values.sorted { $0.key < $1.key }.map {
            $0.key + "=" + ($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&").utf8)
    }
    private func post(_ path: String, values: [String: String]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: authority + path)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form(values)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OneDriveFailure.message("Invalid Microsoft response.") }
        return (data, http)
    }
    func beginLogin() async throws -> OneDriveDeviceCode {
        guard Self.validClientID(clientID) else { throw OneDriveFailure.message("A registered Microsoft Application (client) ID is required.") }
        let (data, http) = try await post("devicecode", values: ["client_id": clientID, "scope": scopes])
        guard http.statusCode == 200 else { throw oauthFailure(data) }
        return try JSONDecoder().decode(OneDriveDeviceCode.self, from: data)
    }
    func completeLogin(_ code: OneDriveDeviceCode) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(code.expires_in))
        var interval = max(1, code.interval ?? 5)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            try Task.checkCancellation()
            let (data, http) = try await post("token", values: ["client_id": clientID,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code", "device_code": code.device_code])
            if http.statusCode == 200 {
                try Task.checkCancellation()
                try accept(data, requireRefresh: true); return
            }
            let reason = try? JSONDecoder().decode(OAuthError.self, from: data)
            if reason?.error == "authorization_pending" { continue }
            if reason?.error == "slow_down" { interval += 5; continue }
            throw oauthFailure(data)
        }
        throw OneDriveFailure.message("The Microsoft sign-in code expired. Please reconnect.")
    }
    private func accept(_ data: Data, requireRefresh: Bool = false) throws {
        let token = try JSONDecoder().decode(Tokens.self, from: data)
        guard !token.access_token.isEmpty, token.expires_in > 0 else { throw OneDriveFailure.message("Invalid Microsoft token response.") }
        if let refresh = token.refresh_token { try store.write(refresh, clientID: clientID) }
        else if requireRefresh { throw OneDriveFailure.message("Microsoft did not grant offline access. Please reconnect.") }
        accessToken = token.access_token
        expiresAt = Date().addingTimeInterval(TimeInterval(token.expires_in) - 60)
    }
    private func oauthFailure(_ data: Data) -> Error {
        let code = (try? JSONDecoder().decode(OAuthError.self, from: data))?.error ?? "unknown_error"
        // Do not expose raw OAuth responses containing device codes or credentials.
        return OneDriveFailure.message("Microsoft sign-in: \(code). Check the app registration/public client settings or reconnect.")
    }
    private func bearer() async throws -> String {
        if let accessToken, expiresAt > Date() { return accessToken }
        guard let refresh = try store.read(clientID: clientID) else {
            throw OneDriveFailure.message("Please connect OneDrive to OpenCommander first.")
        }
        let (data, http) = try await post("token", values: ["client_id": clientID,
            "grant_type": "refresh_token", "refresh_token": refresh, "scope": scopes])
        guard http.statusCode == 200 else {
            if (try? JSONDecoder().decode(OAuthError.self, from: data))?.error == "invalid_grant" {
                try store.write(nil, clientID: clientID)
            }
            throw oauthFailure(data)
        }
        try accept(data)
        return accessToken!
    }
    func disconnect() throws {
        try store.write(nil, clientID: clientID)
        accessToken = nil; expiresAt = .distantPast
    }
    func hasSavedLogin() throws -> Bool { try store.read(clientID: clientID) != nil }
    private func component(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"))!
    }
    private func itemPath(_ id: String?) -> String { id.map { "/me/drive/items/" + component($0) } ?? "/me/drive/root" }
    static func safeGraphURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "graph.microsoft.com" && url.port == nil &&
        url.user == nil && url.password == nil && url.path.hasPrefix("/v1.0/")
    }
    private func request(_ path: String, method: String = "GET", body: Data? = nil, contentType: String = "application/json", matching: String? = nil) async throws -> Data {
        guard let url = URL(string: path.hasPrefix("https:") ? path : graph + path), Self.safeGraphURL(url) else {
            throw OneDriveFailure.message("Refused an unexpected OneDrive API address.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body
        request.setValue("Bearer " + (try await bearer()), forHTTPHeaderField: "Authorization")
        if let matching { request.setValue(matching, forHTTPHeaderField: "If-Match") }
        if body != nil { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OneDriveFailure.message("Invalid OneDrive response.") }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { accessToken = nil; expiresAt = .distantPast }
            if http.statusCode == 409 { throw OneDriveFailure.nameConflict }
            throw OneDriveFailure.message("OneDrive request failed (HTTP \(http.statusCode)). \(http.statusCode == 401 ? "Reconnect your account." : "No success was reported; refresh before retrying a change.")")
        }
        return data
    }
    func children(of id: String? = nil) async throws -> [OneDriveItem] {
        var next: String? = itemPath(id) + "/children?$select=id,name,size,folder,lastModifiedDateTime,eTag&$top=200"
        var visited = Set<String>(); var result: [OneDriveItem] = []
        while let path = next {
            guard visited.insert(path).inserted else { throw OneDriveFailure.message("OneDrive returned a repeated page.") }
            let page = try JSONDecoder().decode(Page.self, from: try await request(path))
            result += page.value; next = page.next
            try Task.checkCancellation()
        }
        return result.sorted { a, b in a.isFolder != b.isFolder ? a.isFolder : a.name.localizedStandardCompare(b.name) == .orderedAscending }
    }
    func createFolder(_ name: String, parent: String?) async throws {
        guard Self.validName(name) else { throw OneDriveFailure.message("Invalid OneDrive name.") }
        let data = try JSONSerialization.data(withJSONObject: ["name": name, "folder": [:], "@microsoft.graph.conflictBehavior": "fail"] as [String: Any])
        _ = try await request(itemPath(parent) + "/children", method: "POST", body: data)
    }
    func rename(_ item: OneDriveItem, to name: String) async throws {
        guard Self.validName(name) else { throw OneDriveFailure.message("Invalid OneDrive name.") }
        _ = try await request(itemPath(item.id), method: "PATCH", body: JSONSerialization.data(withJSONObject: ["name": name, "@microsoft.graph.conflictBehavior": "fail"]), matching: item.eTag)
    }
    func recycle(_ item: OneDriveItem) async throws { _ = try await request(itemPath(item.id), method: "DELETE") }
    func metadata(_ id: String? = nil) async throws -> OneDriveItem {
        try JSONDecoder().decode(OneDriveItem.self, from: try await request(itemPath(id)))
    }
    func validateDestination(_ parent: String?, excluding itemID: String) async throws {
        var next = parent
        var visited = Set<String>()
        while let id = next {
            guard id != itemID, visited.count < 100, visited.insert(id).inserted else { throw OneDriveFailure.message("A folder cannot be transferred into itself or its descendants.") }
            let data = try await request(itemPath(id) + "?$select=id,parentReference")
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            next = (object?["parentReference"] as? [String: Any])?["id"] as? String
        }
    }
    /// Resolve the real root ID: Graph does not accept "root" in parentReference.
    func move(_ item: OneDriveItem, parent: String?, name: String? = nil) async throws {
        if let name, !Self.validName(name) { throw OneDriveFailure.message("Invalid OneDrive name.") }
        let destination: String
        if let parent { destination = parent } else { destination = try await metadata().id }
        guard destination != item.id else { throw OneDriveFailure.message("A folder cannot be moved into itself.") }
        var body: [String: Any] = ["parentReference": ["id": destination], "@microsoft.graph.conflictBehavior": "fail"]
        if let name { body["name"] = name }
        let data = try JSONSerialization.data(withJSONObject: body)
        _ = try await request(itemPath(item.id), method: "PATCH", body: data, matching: item.eTag)
    }

    /// Streaming fingerprints prevent a changed local source from being removed
    /// after uploading a snapshot. Links and special files are never followed.
    nonisolated static func localSnapshot(_ url: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        func visit(_ url: URL, path: String, depth: Int) throws {
            guard depth < 100, result.count < 100_000 else { throw OneDriveFailure.message("Folder transfer limit exceeded.") }
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileResourceIdentifierKey, .contentModificationDateKey])
            guard values.isSymbolicLink != true, Self.validName(url.lastPathComponent) else { throw OneDriveFailure.message("Unsupported link or OneDrive filename: " + url.lastPathComponent) }
            let identity = String(describing: values.fileResourceIdentifier) + String(describing: values.contentModificationDate)
            if values.isDirectory == true {
                result[path] = "directory:" + identity
                for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                    try visit(child, path: path + "/" + child.lastPathComponent, depth: depth + 1)
                }
            } else {
                guard values.isRegularFile == true else { throw OneDriveFailure.message("Only regular files and folders can be transferred.") }
                let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
                var hash = SHA256()
                while let bytes = try file.read(upToCount: 1024 * 1024), !bytes.isEmpty { hash.update(data: bytes) }
                result[path] = identity + hash.finalize().map { String(format: "%02x", $0) }.joined()
            }
        }
        try visit(url, path: "", depth: 0)
        return result
    }
    func uploadTree(_ url: URL, parent: String?) async throws {
        _ = try await Task.detached { try Self.localSnapshot(url) }.value
        try await uploadTreeValidated(url, parent: parent, depth: 0)
    }
    private func uploadTreeValidated(_ url: URL, parent: String?, depth: Int) async throws {
        try Task.checkCancellation()
        guard depth < 100 else { throw OneDriveFailure.message("Folder transfer limit exceeded.") }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw OneDriveFailure.message("Symbolic links cannot be uploaded.") }
        if values.isDirectory == true {
            let body = try JSONSerialization.data(withJSONObject: ["name": url.lastPathComponent, "folder": [:], "@microsoft.graph.conflictBehavior": "fail"] as [String: Any])
            let folder = try JSONDecoder().decode(OneDriveItem.self, from: try await request(itemPath(parent) + "/children", method: "POST", body: body))
            for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                try await uploadTreeValidated(child, parent: folder.id, depth: depth + 1)
            }
        } else { try await upload(url, parent: parent) }
    }
    func upload(_ url: URL, parent: String?) async throws {
        guard Self.validName(url.lastPathComponent) else { throw OneDriveFailure.message("Invalid OneDrive name.") }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize else { throw OneDriveFailure.message("Select a regular file.") }
        if size > 10 * 1024 * 1024 { try await uploadChunks(url, size: size, parent: parent); return }
        let data = try Data(contentsOf: url)
        guard data.count <= 20 * 1024 * 1024 else { throw OneDriveFailure.message("The file exceeds 20 MB.") }
        let reply = try await request(itemPath(parent) + ":/" + component(url.lastPathComponent) + ":/content?@microsoft.graph.conflictBehavior=fail",
            method: "PUT", body: data, contentType: "application/octet-stream")
        let uploaded = try JSONDecoder().decode(OneDriveItem.self, from: reply)
        guard uploaded.size == Int64(data.count) else { throw OneDriveFailure.message("Uploaded size mismatch. Source retained.") }
    }
    private func uploadChunks(_ file: URL, size: Int, parent: String?) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["item": ["@microsoft.graph.conflictBehavior": "fail", "name": file.lastPathComponent]])
        let data = try await request(itemPath(parent) + ":/" + component(file.lastPathComponent) + ":/createUploadSession", method: "POST", body: body)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let address = object?["uploadUrl"] as? String, let url = URL(string: address), url.scheme == "https", url.user == nil, url.password == nil else { throw OneDriveFailure.message("Invalid upload address.") }
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var offset = 0
        while offset < size {
            try Task.checkCancellation()
            let expected = min(10 * 327_680, size - offset)
            guard let chunk = try handle.read(upToCount: expected), chunk.count == expected else { throw OneDriveFailure.message("Source changed during upload.") }
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"; request.httpBody = chunk
            request.setValue("bytes \(offset)-\(offset + chunk.count - 1)/\(size)", forHTTPHeaderField: "Content-Range")
            request.setValue(String(chunk.count), forHTTPHeaderField: "Content-Length")
            // The upload URL is preauthenticated. Never send our Graph token.
            let (reply, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.url?.scheme == "https" else { throw OneDriveFailure.message("Invalid upload response.") }
            offset += chunk.count
            if offset == size {
                guard http.statusCode == 200 || http.statusCode == 201 else { throw OneDriveFailure.message("Upload was not committed (HTTP \(http.statusCode)). Source retained.") }
                let item = try JSONDecoder().decode(OneDriveItem.self, from: reply)
                guard item.size == Int64(size) else { throw OneDriveFailure.message("Uploaded size mismatch. Source retained.") }
            } else {
                let state = try JSONSerialization.jsonObject(with: reply) as? [String: Any]
                guard http.statusCode == 202, (state?["nextExpectedRanges"] as? [String])?.first == "\(offset)-" else { throw OneDriveFailure.message("Unexpected upload offset. Source retained; refresh before retrying.") }
            }
        }
    }
    /// Materialize folders in an isolated temporary container, then validate
    /// their version manifest before a caller may perform a move.
    func remoteSnapshot(_ item: OneDriveItem) async throws -> [String: String] {
        var result: [String: String] = [:]
        func visit(_ item: OneDriveItem, depth: Int) async throws {
            try Task.checkCancellation()
            guard depth < 100, result.count < 100_000, result[item.id] == nil else { throw OneDriveFailure.message("Invalid or oversized folder tree.") }
            let current = try await metadata(item.id)
            guard let tag = current.eTag else { throw OneDriveFailure.message("OneDrive did not provide a version for safe transfer.") }
            result[item.id] = tag
            if current.isFolder { for child in try await children(of: current.id) { try await visit(child, depth: depth + 1) } }
        }
        try await visit(item, depth: 0); return result
    }
    func recycleUnchanged(_ item: OneDriveItem, snapshot: [String: String]) async throws {
        guard try await remoteSnapshot(item) == snapshot, let tag = snapshot[item.id] else { throw OneDriveFailure.message("Online source changed. Both copies have been retained.") }
        // A folder eTag does not atomically guard all its descendants. Preserve
        // the folder instead of risking removal of concurrently added content.
        guard !item.isFolder else { throw OneDriveFailure.message("The folder was copied successfully. Its online source was retained because OneDrive cannot atomically verify every child during removal. Move folders within OneDrive, or review and recycle the source explicitly.") }
        _ = try await request(itemPath(item.id), method: "DELETE", matching: tag)
    }
    func downloadTree(_ item: OneDriveItem) async throws -> URL {
        guard Self.validName(item.name) else { throw OneDriveFailure.message("Unsafe remote filename.") }
        if !item.isFolder { return try await download(item) }
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("OpenCommander-OneDrive-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false)
        let root = container.appendingPathComponent(item.name, isDirectory: true)
        var seen = Set<String>()
        func visit(_ item: OneDriveItem, at destination: URL, depth: Int) async throws {
            try Task.checkCancellation()
            guard Self.validName(item.name), depth < 100, seen.count < 100_000, seen.insert(item.id).inserted else { throw OneDriveFailure.message("Unsafe or oversized remote tree.") }
            if item.isFolder {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                for child in try await children(of: item.id) { try await visit(child, at: destination.appendingPathComponent(child.name), depth: depth + 1) }
            } else {
                let downloaded = try await download(item)
                defer { try? FileManager.default.removeItem(at: downloaded.deletingLastPathComponent()) }
                try FileManager.default.moveItem(at: downloaded, to: destination)
            }
        }
        do { try await visit(item, at: root, depth: 0); return root }
        catch { try? FileManager.default.removeItem(at: container); throw error }
    }
    func download(_ item: OneDriveItem) async throws -> URL {
        guard !item.isFolder, Self.validName(item.name) else { throw OneDriveFailure.message("Select an individual file to download.") }
        // Graph metadata yields a short-lived preauthenticated URL. Never forward the bearer token to it.
        // downloadUrl is an instance annotation, not an ordinary selectable
        // property. Request the default metadata so Graph includes it.
        let data = try await request(itemPath(item.id))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        // The list/clipboard may predate upload processing or later edits. A
        // read copies the current version, not the stale selection's eTag.
        let current = try JSONDecoder().decode(OneDriveItem.self, from: data)
        guard current.id == item.id, !current.isFolder, current.name == item.name,
              let version = current.cTag ?? current.eTag else {
            throw OneDriveFailure.message("OneDrive could not confirm the current file name/version. Refresh the folder and retry. Source retained.")
        }
        guard let address = object?["@microsoft.graph.downloadUrl"] as? String,
              let url = URL(string: address), url.scheme == "https", url.user == nil, url.password == nil else {
            throw OneDriveFailure.message("OneDrive did not provide a secure download address.")
        }
        let (temporary, response) = try await downloadFile(url)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url?.scheme == "https" else {
            throw OneDriveFailure.message("OneDrive download failed.")
        }
        if let size = object?["size"] as? NSNumber {
            guard try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize == size.intValue else { throw OneDriveFailure.message("Incomplete download. Source retained.") }
        }
        // cTag identifies content only; eTag also changes for metadata. Pin the
        // freshly fetched content version across the actual download. Moves
        // still independently use their full eTag snapshot before deletion.
        let after = try await metadata(item.id)
        let afterVersion = current.cTag != nil ? after.cTag : after.eTag
        guard after.id == current.id, !after.isFolder, after.name == current.name,
              after.size == current.size, afterVersion == version else {
            let german = (UserDefaults.standard.string(forKey: "language") ?? Locale.current.language.languageCode?.identifier ?? "en").hasPrefix("de")
            throw OneDriveFailure.message(german
                ? "Die OneDrive-Datei wurde während des Downloads verändert. Bitte erneut kopieren. Die Quelle bleibt erhalten."
                : "The OneDrive file changed during download. Copy it again. The source has been retained.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OpenCommander-OneDrive-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(item.name)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }
}
