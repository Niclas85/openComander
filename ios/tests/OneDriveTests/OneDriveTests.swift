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
    static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
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

        let file = try JSONDecoder().decode(OneDriveItem.self, from: Data(#"{"id":"fixture-id","name":"fixture.txt","size":7,"eTag":"fixture-v1"}"#.utf8))
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
        check(requests[1].value(forHTTPHeaderField: "If-Match") == "fixture-v1", "Rename and undo protect against concurrent changes")
        let renameBody = try JSONSerialization.jsonObject(with: body(requests[1])) as! [String: Any]
        check(renameBody["@microsoft.graph.conflictBehavior"] as? String == "fail", "Rename never replaces a destination")
        let before = requests.count
        for invalid in ["../escape", "bad\\name", "bad:name", "trailing.", "", "..", "\n"] {
            do { try await api.createFolder(invalid, parent: nil); fatalError("Invalid name accepted") } catch { }
        }
        check(requests.count == before, "Invalid names cause no requests")
        print("PASS create/rename/recycle requests and invalid name protection")

        check(OneDriveConflictNames.available("Photo.JPG", folder: false, existing: ["photo.jpg", "PHOTO (2).jpg"]) == "Photo (3).JPG", "Keep both is case insensitive and preserves extension")
        check(OneDriveConflictNames.available("Grüsse.txt", folder: false, existing: ["Gru\u{0308}sse.txt"]) == "Grüsse (2).txt", "Canonically equivalent Unicode names conflict")
        check(OneDriveConflictNames.available("Folder.v1", folder: true, existing: ["Folder.v1"]) == "Folder.v1 (2)", "Folder dots are not extensions")
        check(OneDriveConflictNames.available(".env", folder: false, existing: [".env"]) == ".env (2)", "Extensionless dotfiles retain their name")
        check(OneDriveConflictNames.available("new.txt", folder: false, existing: []) == "new.txt", "No conflict keeps original name")
        let longName = String(repeating: "x", count: 251) + ".txt"
        check(OneDriveClient.validName(OneDriveConflictNames.available(longName, folder: false, existing: [longName])), "Numbered name stays within name limit")
        let longExtension = "x." + String(repeating: "e", count: 253)
        check(OneDriveClient.validName(OneDriveConflictNames.available(longExtension, folder: false, existing: [longExtension])), "Extreme extension cannot exceed numbered name limit")
        print("PASS safe conflict names, case/Unicode equivalence, folders, extensions and length limit")

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
        do { try await api.upload(large, parent: nil); fatalError("Failed session accepted") } catch { }
        check(count + 1 == requests.count && requests.last?.url?.path.hasSuffix("createUploadSession") == true, "Large upload uses a session")
        print("PASS failed upload propagates, collision refusal, encoding, upload-session failure")

        var offset = 0
        let total = 20 * 1024 * 1024 + 1
        MockMicrosoft.handler = { request in
            if request.url!.host == "graph.microsoft.com" {
                check(request.httpMethod == "POST", "Session creation uses POST")
                check(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-access", "Only session creation receives Graph token")
                return (200, #"{"uploadUrl":"https://upload.example/fixture"}"#)
            }
            check(request.value(forHTTPHeaderField: "Authorization") == nil, "Upload chunks never contain a Graph bearer")
            let bytes = body(request).count
            check(request.value(forHTTPHeaderField: "Content-Range") == "bytes \(offset)-\(offset + bytes - 1)/\(total)", "Contiguous byte ranges")
            offset += bytes
            if offset == total { return (201, "{\"id\":\"large\",\"name\":\"large.bin\",\"size\":\(total)}") }
            check(bytes % 327_680 == 0, "Intermediate chunk multiple of 320 KiB")
            return (202, "{\"nextExpectedRanges\":[\"\(offset)-\"]}")
        }
        try await api.upload(large, parent: nil)
        check(offset == total, "All large-file bytes sent")
        MockMicrosoft.handler = { request in
            if request.url!.host == "graph.microsoft.com" { return (200, #"{"uploadUrl":"https://upload.example/fixture"}"#) }
            return (202, #"{"nextExpectedRanges":["0-"]}"#)
        }
        do { try await api.upload(large, parent: nil); fatalError("Unexpected chunk offset accepted") } catch { }
        check(FileManager.default.fileExists(atPath: large.path), "Failed chunk upload retains the source")
        let beforeSnapshot = try OneDriveClient.localSnapshot(local)
        try Data("changed".utf8).write(to: local)
        let afterSnapshot = try OneDriveClient.localSnapshot(local)
        check(afterSnapshot != beforeSnapshot, "Same-size edits change source fingerprint")
        let link = fixture.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: local)
        do { _ = try OneDriveClient.localSnapshot(link); fatalError("Link followed") } catch { }
        print("PASS large-file streaming, byte ranges, credential separation, fingerprints, links")

        requests = []
        MockMicrosoft.handler = { request in
            requests.append(request)
            if request.httpMethod == "GET" { return (200, #"{"id":"actual-root","name":"root","folder":{}}"#) }
            let object = try JSONSerialization.jsonObject(with: body(request)) as! [String: Any]
            check((object["parentReference"] as? [String: String])?["id"] == "actual-root", "Move to root uses actual ID")
            check(object["@microsoft.graph.conflictBehavior"] as? String == "fail", "Move refuses name conflicts")
            return (200, "{}")
        }
        try await api.move(file, parent: nil)
        check(requests.map(\.httpMethod) == ["GET", "PATCH"], "Root lookup then server-side move")
        requests = []
        MockMicrosoft.handler = { request in
            requests.append(request)
            let object = try JSONSerialization.jsonObject(with: body(request)) as! [String: Any]
            check(object["name"] as? String == "Grüsse (2).txt", "Keep Both name sent atomically with move")
            check((object["parentReference"] as? [String: String])?["id"] == "target", "Move and rename share one request")
            check(request.value(forHTTPHeaderField: "If-Match") == file.eTag, "Conflict-safe move retains version condition")
            return (200, "{}")
        }
        try await api.move(file, parent: "target", name: "Grüsse (2).txt")
        check(requests.count == 1, "No source rename before successful move")
        MockMicrosoft.handler = { _ in (409, #"{"error":{"code":"nameAlreadyExists"}}"#) }
        do { try await api.move(file, parent: "target"); fatalError("Name collision falsely succeeded") }
        catch OneDriveFailure.nameConflict { }
        print("PASS atomic conflict-name moves and typed 409 failures")
        let folder = try JSONDecoder().decode(OneDriveItem.self, from: Data(#"{"id":"folder","name":"Folder","folder":{},"eTag":"v1"}"#.utf8))
        MockMicrosoft.handler = { request in
            if request.url!.path.hasSuffix("child") { return (200, #"{"id":"child","parentReference":{"id":"folder"}}"#) }
            fatalError("Descendant check must stop before traversing the source")
        }
        do { try await api.validateDestination("child", excluding: "folder"); fatalError("Descendant destination accepted") } catch { }
        print("PASS server-side move, real root ID, collisions, descendant protection")

        let nested = fixture.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        try Data("abc".utf8).write(to: nested.appendingPathComponent("child.txt"))
        requests = []
        MockMicrosoft.handler = { request in
            requests.append(request)
            if request.httpMethod == "POST" { return (201, #"{"id":"new-folder","name":"Nested","folder":{}}"#) }
            check(request.url!.path.contains("new-folder:/child.txt:/content"), "Child uploaded into created directory")
            return (201, #"{"id":"new-child","name":"child.txt","size":3}"#)
        }
        try await api.uploadTree(nested, parent: nil)
        check(requests.map(\.httpMethod) == ["POST", "PUT"], "Folder and child upload")
        var version = "v1"
        var deletes = 0
        let versioned = try JSONDecoder().decode(OneDriveItem.self, from: Data(#"{"id":"versioned","name":"test.txt","size":3,"eTag":"v1"}"#.utf8))
        MockMicrosoft.handler = { request in
            if request.httpMethod == "DELETE" {
                deletes += 1
                check(request.value(forHTTPHeaderField: "If-Match") == "v1", "Move deletion is conditional on source version")
                return (412, "{}")
            }
            return (200, "{\"id\":\"versioned\",\"name\":\"test.txt\",\"size\":3,\"eTag\":\"\(version)\"}")
        }
        let manifest = try await api.remoteSnapshot(versioned)
        version = "v2"
        do { try await api.recycleUnchanged(versioned, snapshot: manifest); fatalError("Changed source removed") } catch { }
        check(deletes == 0, "Changed remote source never deleted")
        version = "v1"
        do { try await api.recycleUnchanged(versioned, snapshot: manifest); fatalError("Failed conditional removal accepted") } catch { }
        check(deletes == 1, "Conditional failure propagates")
        MockMicrosoft.handler = { request in
            if request.url!.path.hasSuffix("children") { return (200, #"{"value":[]}"#) }
            check(request.httpMethod != "DELETE", "Folder must never be recursively deleted by a cross-storage move")
            return (200, #"{"id":"folder","name":"Folder","folder":{},"eTag":"v1"}"#)
        }
        let folderManifest = try await api.remoteSnapshot(folder)
        do { try await api.recycleUnchanged(folder, snapshot: folderManifest); fatalError("Folder source removed without an atomic descendant guard") } catch { }
        print("PASS folder upload, source-change protection, conditional deletion failure")

        @MainActor func checkDownload(before: String, after: String, contentBefore: String?, contentAfter: String?, succeeds: Bool) async throws {
            var reads = 0
            var temporary: URL?
            MockMicrosoft.handler = { request in
                if request.url!.host == "login.microsoftonline.com" {
                    return (200, #"{"access_token":"fixture-access","refresh_token":"fixture-refresh","expires_in":3600}"#)
                }
                check(request.httpMethod == "GET", "Copy download never mutates its source")
                reads += 1
                var metadata: [String: Any] = ["id": "versioned", "name": "test.txt", "size": 3,
                    "eTag": reads == 1 ? before : after,
                    "@microsoft.graph.downloadUrl": "https://download.example/test"]
                if let tag = reads == 1 ? contentBefore : contentAfter { metadata["cTag"] = tag }
                return (200, String(data: try JSONSerialization.data(withJSONObject: metadata), encoding: .utf8)!)
            }
            let reader = OneDriveClient(clientID: id, session: session, store: MemoryTokens(), downloadFile: { url in
                check(url.host == "download.example", "Only metadata-provided download URL used")
                let staged = fixture.appendingPathComponent("download-" + UUID().uuidString)
                temporary = staged
                try Data("abc".utf8).write(to: staged)
                return (staged, HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
            })
            do {
                // `versioned` was selected with an older v1 eTag. Reads must
                // fetch a fresh version rather than rejecting that stale list.
                let downloaded = try await reader.download(versioned)
                check(succeeds, "Changed content must not be published")
                let content = try String(contentsOf: downloaded, encoding: .utf8)
                check(content == "abc", "Complete current content copied")
                try FileManager.default.removeItem(at: downloaded.deletingLastPathComponent())
            } catch { if succeeds { throw error } }
            check(reads == 2, "Current version checked before and after download")
            if let temporary { check(!FileManager.default.fileExists(atPath: temporary.path), "Downloaded staging cleaned on success/failure") }
        }
        try await checkDownload(before: "fresh-v2", after: "fresh-v2", contentBefore: nil, contentAfter: nil, succeeds: true)
        try await checkDownload(before: "fresh-v2", after: "metadata-v3", contentBefore: "content-v2", contentAfter: "content-v2", succeeds: true)
        try await checkDownload(before: "fresh-v2", after: "edited-v3", contentBefore: "content-v2", contentAfter: "content-v3", succeeds: false)
        try await checkDownload(before: "fresh-v2", after: "edited-v3", contentBefore: nil, contentAfter: nil, succeeds: false)
        try await checkDownload(before: "fresh-v2", after: "metadata-v3", contentBefore: "content-v2", contentAfter: nil, succeeds: false)
        print("PASS fresh download snapshots, stale-list recovery, metadata-only changes and concurrent-content protection")

        MockMicrosoft.handler = { request in
            check(request.url!.query == nil, "Default metadata requested for download annotation")
            let metadata: [String: Any] = ["id": file.id, "name": file.name, "eTag": "fresh", "size": 3,
                "@microsoft.graph.downloadUrl": "http://unsafe.example/fixture"]
            return (200, String(data: try JSONSerialization.data(withJSONObject: metadata), encoding: .utf8)!)
        }
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
