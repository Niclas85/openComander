import Foundation

final class MemoryTokens: OneDriveTokenStore {
    var value: String? = "fixture-refresh"
    func read(clientID: String) throws -> String? { value }
    func write(_ token: String?, clientID: String) throws { value = token }
}

final class MockMicrosoft: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, json) = try Self.handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(json.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main struct OneDriveTests {
    static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        if !condition() { fatalError("FAIL: " + label) }
    }
    @MainActor static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockMicrosoft.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let store = MemoryTokens()
        let id = "00000000-0000-0000-0000-000000000001"
        let api = OneDriveClient(clientID: id, session: session, store: store)
        var requests: [URLRequest] = []
        MockMicrosoft.handler = { request in
            requests.append(request)
            if request.url!.host == "login.microsoftonline.com" {
                check(request.value(forHTTPHeaderField: "Authorization") == nil, "Graph token must not reach OAuth endpoint")
                return (200, #"{"access_token":"fixture-access","refresh_token":"rotated-refresh","expires_in":3600}"#)
            }
            check(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-access", "Graph receives access token")
            if request.url!.query == "page=2" { return (200, #"{"value":[{"id":"2","name":"Alpha","folder":{"childCount":0}}]}"#) }
            return (200, #"{"value":[{"id":"1","name":"Grüsse.txt","size":42}],"@odata.nextLink":"https://graph.microsoft.com/v1.0/me/drive/root/children?page=2"}"#)
        }
        let listing = try await api.children()
        check(listing.count == 2 && listing.first?.isFolder == true, "Pagination and folder-first sorting")
        check(listing.last?.name == "Grüsse.txt", "Unicode filenames")
        check(store.value == "rotated-refresh", "Refresh rotation is persisted")
        check(requests.count == 3, "Exactly one refresh and two listing pages")
        _ = try await api.children()
        check(requests.count == 5, "Unexpired access token reused")
        print("PASS refresh, rotation, pagination, Unicode, token reuse")

        requests = []
        MockMicrosoft.handler = { request in
            requests.append(request)
            return (200, #"{"value":[],"@odata.nextLink":"https://untrusted.example/v1.0/steal"}"#)
        }
        do { _ = try await api.children(); fatalError("Unexpected foreign page accepted") }
        catch { check(requests.count == 1, "Untrusted pagination never requested") }
        check(!OneDriveClient.safeGraphURL(URL(string: "http://graph.microsoft.com/v1.0/me/drive")!), "Reject HTTP")
        check(!OneDriveClient.safeGraphURL(URL(string: "https://graph.microsoft.com:8443/v1.0/me/drive")!), "Reject alternate port")
        check(!OneDriveClient.safeGraphURL(URL(string: "https://graph.microsoft.com.attacker.example/v1.0/me/drive")!), "Reject lookalike host")
        check(!OneDriveClient.allowedRedirect(from: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token"), to: URL(string: "https://untrusted.example/token")), "OAuth body cannot follow a foreign redirect")
        check(!OneDriveClient.allowedRedirect(from: URL(string: "https://graph.microsoft.com/v1.0/me/drive"), to: URL(string: "https://untrusted.example/")), "Bearer request cannot follow a foreign redirect")
        check(!OneDriveClient.allowedRedirect(from: URL(string: "https://download.example/file"), to: URL(string: "http://download.example/file")), "Download cannot downgrade TLS")
        print("PASS unexpected pagination URL and insecure API addresses refused")

        MockMicrosoft.handler = { _ in (200, #"{"value":[],"@odata.nextLink":"https://graph.microsoft.com/v1.0/me/drive/root/children"}"#) }
        do { _ = try await api.children(); fatalError("Repeated page accepted") } catch { }
        print("PASS pagination loop detection")

        let file = try JSONDecoder().decode(OneDriveItem.self, from: Data(#"{"id":"fixture-id","name":"fixture.txt","size":7}"#.utf8))
        requests = []
        MockMicrosoft.handler = { request in
            requests.append(request)
            if request.httpMethod == "POST" || request.httpMethod == "PATCH" { return (201, "{}") }
            if request.httpMethod == "DELETE" { return (204, "") }
            return (409, #"{"error":{"code":"nameAlreadyExists"}}"#)
        }
        try await api.createFolder("Grüsse", parent: nil)
        try await api.rename(file, to: "Renamed.txt")
        try await api.recycle(file)
        check(requests.map(\.httpMethod) == ["POST", "PATCH", "DELETE"], "Correct mutation methods")
        let before = requests.count
        for invalid in ["../escape", "bad\\name", "bad:name", "trailing.", "", "..", "\n"] {
            do { try await api.createFolder(invalid, parent: nil); fatalError("Invalid name accepted") } catch { }
        }
        check(requests.count == before, "Invalid names cause no requests")
        print("PASS create/rename/recycle requests and invalid name protection")

        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("OpenCommander-OneDriveTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let local = fixture.appendingPathComponent("Grüsse.txt")
        try Data("fixture".utf8).write(to: local)
        do { try await api.upload(local, parent: nil); fatalError("Failed upload falsely succeeded") } catch { }
        check(requests.last?.httpMethod == "PUT", "Upload uses PUT")
        check(requests.last?.url?.query?.contains("conflictBehavior=fail") == true, "Upload explicitly refuses replacement")
        check(requests.last?.url?.path.contains("Grüsse.txt") == true, "Upload preserves Unicode after URL decoding")
        let large = fixture.appendingPathComponent("large.bin")
        try Data().write(to: large)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: 20 * 1024 * 1024 + 1); try handle.close()
        let count = requests.count
        do { try await api.upload(large, parent: nil); fatalError("Oversize upload accepted") } catch { }
        check(count == requests.count, "Oversize file blocked before upload")
        print("PASS failed upload propagates, collision refusal, encoding, size guard")

        MockMicrosoft.handler = { _ in (200, #"{"@microsoft.graph.downloadUrl":"http://unsafe.example/fixture"}"#) }
        do { _ = try await api.download(file); fatalError("HTTP download URL accepted") } catch { }
        try api.disconnect(); check(store.value == nil, "Disconnect removes credential")
        let disconnectedCount = requests.count
        do { _ = try await api.children(); fatalError("Disconnected account used") } catch { }
        check(disconnectedCount == requests.count, "No account request after disconnect")
        print("PASS secure download URL guard and disconnect")

        let loginStore = MemoryTokens(); loginStore.value = nil
        let login = OneDriveClient(clientID: id, session: session, store: loginStore)
        var polls = 0
        MockMicrosoft.handler = { request in
            if request.url!.path.hasSuffix("devicecode") {
                return (200, #"{"device_code":"fixture-device","user_code":"FIXTURE","verification_uri":"https://microsoft.com/devicelogin","expires_in":30,"interval":1}"#)
            }
            polls += 1
            if polls == 1 { return (400, #"{"error":"authorization_pending"}"#) }
            return (200, #"{"access_token":"fixture-access","refresh_token":"fixture-refresh","expires_in":3600}"#)
        }
        let code = try await login.beginLogin()
        try await login.completeLogin(code)
        check(polls == 2 && loginStore.value == "fixture-refresh", "Device polling persists authorized credential")
        let cancelled = Task { try await login.completeLogin(code) }
        cancelled.cancel()
        do { try await cancelled.value; fatalError("Cancelled login continued") } catch is CancellationError { }
        check(polls == 2, "Cancelled login makes no requests")
        let expired = OneDriveDeviceCode(device_code: "expired", user_code: "EXPIRED", verification_uri: "https://microsoft.com/devicelogin", expires_in: 0, interval: 1)
        do { try await login.completeLogin(expired); fatalError("Expired device code accepted") } catch { }
        check(polls == 2, "Expired code makes no token requests")
        print("PASS device-code pending/success and cancellation")

        let deniedStore = MemoryTokens()
        let denied = OneDriveClient(clientID: id, session: session, store: deniedStore)
        MockMicrosoft.handler = { _ in (400, #"{"error":"invalid_grant","error_description":"sensitive fixture"}"#) }
        do { _ = try await denied.children(); fatalError("Expired refresh accepted") }
        catch { check(!error.localizedDescription.contains("sensitive"), "Raw OAuth response is not exposed") }
        check(deniedStore.value == nil, "Revoked refresh token removed")
        print("PASS revoked credential and sanitized OAuth errors")
    }
}
