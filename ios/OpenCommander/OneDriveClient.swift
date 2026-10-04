import Foundation
import Security

struct OneDriveItem: Decodable {
    struct Folder: Decodable { let childCount: Int? }
    let id: String
    let name: String
    let size: Int64?
    let folder: Folder?
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
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
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

    init(clientID: String, session: URLSession? = nil, store: OneDriveTokenStore = OneDriveKeychain()) {
        self.clientID = clientID; self.store = store
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.timeoutIntervalForRequest = 60
            self.session = URLSession(configuration: configuration, delegate: OneDriveRedirectGuard(), delegateQueue: nil)
        }
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
    static func validName(_ name: String) -> Bool {
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
    private func request(_ path: String, method: String = "GET", body: Data? = nil, contentType: String = "application/json") async throws -> Data {
        guard let url = URL(string: path.hasPrefix("https:") ? path : graph + path), Self.safeGraphURL(url) else {
            throw OneDriveFailure.message("Refused an unexpected OneDrive API address.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body
        request.setValue("Bearer " + (try await bearer()), forHTTPHeaderField: "Authorization")
        if body != nil { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OneDriveFailure.message("Invalid OneDrive response.") }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { accessToken = nil; expiresAt = .distantPast }
            throw OneDriveFailure.message("OneDrive request failed (HTTP \(http.statusCode)). \(http.statusCode == 401 ? "Reconnect your account." : "No success was reported; refresh before retrying a change.")")
        }
        return data
    }
    func children(of id: String? = nil) async throws -> [OneDriveItem] {
        var next: String? = itemPath(id) + "/children?$select=id,name,size,folder&$top=200"
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
        _ = try await request(itemPath(item.id), method: "PATCH", body: JSONSerialization.data(withJSONObject: ["name": name]))
    }
    func recycle(_ item: OneDriveItem) async throws { _ = try await request(itemPath(item.id), method: "DELETE") }
    func upload(_ url: URL, parent: String?) async throws {
        guard Self.validName(url.lastPathComponent) else { throw OneDriveFailure.message("Invalid OneDrive name.") }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 20 * 1024 * 1024 else {
            throw OneDriveFailure.message("This initial online browser supports uploading individual files up to 20 MB.")
        }
        let data = try Data(contentsOf: url)
        guard data.count <= 20 * 1024 * 1024 else { throw OneDriveFailure.message("The file exceeds 20 MB.") }
        _ = try await request(itemPath(parent) + ":/" + component(url.lastPathComponent) + ":/content?@microsoft.graph.conflictBehavior=fail",
            method: "PUT", body: data, contentType: "application/octet-stream")
    }
    func download(_ item: OneDriveItem) async throws -> URL {
        guard !item.isFolder, Self.validName(item.name) else { throw OneDriveFailure.message("Select an individual file to download.") }
        // Graph metadata yields a short-lived preauthenticated URL. Never forward the bearer token to it.
        let data = try await request(itemPath(item.id) + "?$select=id,name,@microsoft.graph.downloadUrl")
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let address = object?["@microsoft.graph.downloadUrl"] as? String,
              let url = URL(string: address), url.scheme == "https", url.user == nil, url.password == nil else {
            throw OneDriveFailure.message("OneDrive did not provide a secure download address.")
        }
        let (temporary, response) = try await session.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url?.scheme == "https" else {
            throw OneDriveFailure.message("OneDrive download failed.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OpenCommander-OneDrive-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(item.name)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }
}
