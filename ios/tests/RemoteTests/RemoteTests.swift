import Foundation

func check(_ value: Bool, _ message: String) {
    if !value { fatalError(message) }
}
@main struct RemoteTests {
    @MainActor static func main() async throws {
        var profile = RemoteConnection(name: "QA", scheme: "ftp", host: "127.0.0.1", port: 21, user: "fixture", root: "/", keyPath: "")
        try profile.validate()
        check(profile.contains("/folder/file"), "absolute remote path")
        check(!profile.contains("/folder/../escape"), "traversal refused")
        profile.root = "/base"
        check(profile.contains("/base/a") && !profile.contains("/base2/a"), "path boundary")
        profile.host = "-oProxyCommand=evil"
        do { try profile.validate(); fatalError("option injection accepted") } catch { }
        let parsed = try RemoteDirectoryItem.mlsd("type=file;size=4;modify=20261008010101; Grüße x.txt\r\ntype=dir; Ordner\r\ntype=pdir; ..\r\n")
        check(parsed.count == 2 && parsed[0].name == "Grüße x.txt", "MLSD Unicode and spaces")
        let ssh = try RemoteDirectoryItem.sftp("sftp> ls -ln \"/\"\n-rw-r--r-- 1 1000 1000 4 Oct 8 12:00 /Grüße x.txt\ndrwxr-xr-x 2 1000 1000 0 Oct 8 12:00 /Ordner\n")
        check(ssh.count == 2 && ssh[0].name == "Grüße x.txt", "SFTP listing Unicode and spaces")
        print("PASS profiles, traversal/option rejection, MLSD and SFTP parsing")
        check(try CommanderOnlineTools.matches("Grüße.TXT", query: "grÜße.*", caseSensitive: false), "online Unicode/glob search")
        check(try !CommanderOnlineTools.matches("Grüße.TXT", query: "grüße.*", caseSensitive: true), "online match-case option")
        fflush(stdout)
        guard CommandLine.arguments.count == 4 else { return }
        let python = CommandLine.arguments[1], directory = URL(fileURLWithPath: CommandLine.arguments[2])
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = Process(), pipe = Pipe(), input = Pipe()
        fixture.executableURL = URL(fileURLWithPath: python)
        fixture.arguments = ["ios/tests/RemoteTests/fixture.py", directory.appendingPathComponent("server").path]
        fixture.standardOutput = pipe; fixture.standardInput = input; fixture.standardError = FileHandle.nullDevice
        try fixture.run()
        defer { try? input.fileHandleForWriting.write(contentsOf: Data("stop\n".utf8)); try? input.fileHandleForWriting.close(); fixture.terminate() }
        var data = Data()
        while let byte = try pipe.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
            if byte == Data([10]) { break }; data.append(byte)
        }
        let settings = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let bridge = DesktopBridge()
        bridge.sshAskPassURL = URL(fileURLWithPath: CommandLine.arguments[3])
        for mode in ["ftp", "ftps", "sftp", "sftp-password"] {
            let scheme = mode == "sftp-password" ? "sftp" : mode
            print("Testing live \(scheme)"); fflush(stdout)
            let connection = RemoteConnection(name: scheme, scheme: scheme, host: "127.0.0.1", port: settings[scheme] as! Int,
                user: mode == "sftp-password" ? "password" : "fixture", root: "/", keyPath: scheme == "sftp" ? settings["key"] as! String : "",
                trustedHostKeys: scheme == "sftp" ? settings["hostKeys"] as? String : nil,
                passwordAuthentication: mode == "sftp-password", tlsCAPath: scheme == "ftps" ? settings["ca"] as? String : nil)
            if scheme == "sftp" {
                let encoded = try JSONEncoder().encode(connection)
                let keys: String = try await withCheckedThrowingContinuation { continuation in
                    bridge.remoteHostKeys(encoded) { keys, error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume(returning: keys ?? "") }
                    }
                }
                check(try RemoteConnection.fingerprints(keys) == RemoteConnection.fingerprints(connection.trustedHostKeys!), "in-app host-key scan")
            }
            let client = RemoteFileClient(connection, transport: { id, connection, password, operation, path, destination, local, completion in
                bridge.remoteOperation(id, connection: connection, password: password, operation: operation, path: path,
                    destination: destination, localURL: local, completion: completion)
            }, cancel: { bridge.cancelRemoteOperation($0) }, password: { "test-only-password" })
            let listing = try await client.children()
            var progressEvents: [(String, Int64, Int64)] = []
            client.transferProgress = { progressEvents.append(($0, $1, $2)) }
            check(listing.contains { $0.name == "Grüsse mit Leerzeichen.txt" }, "live listing")
            let original = listing.first { !$0.isFolder }!
            let downloaded = try await client.download(original)
            check(try String(contentsOf: downloaded, encoding: .utf8) == "OpenCommander FTP/SFTP fixture\n", "download integrity")
            try? fm.removeItem(at: downloaded.deletingLastPathComponent())
            do { _ = try await CommanderOnlineTools.resolve("/../escape", client: client); fatalError("unsafe tool path accepted") } catch { }
            do { _ = try await CommanderOnlineTools.renamePlan(client, parent: nil, selected: [original], fields: ["Ordner", "", "", "1", "3"]); fatalError("occupied tool rename accepted") } catch { }
            let hiddenFile = directory.appendingPathComponent("server/.Hidden-QA")
            try Data("hidden".utf8).write(to: hiddenFile)
            check(!(try await CommanderOnlineTools.scan(client, ancestors: [], hidden: false)).contains { $0.item.name == ".Hidden-QA" }, "online hidden filter")
            check((try await CommanderOnlineTools.scan(client, ancestors: [], hidden: true)).contains { $0.item.name == ".Hidden-QA" }, "online hidden inclusion")
            try fm.removeItem(at: hiddenFile)
            if scheme == "sftp" {
                let link = directory.appendingPathComponent("server/Unsafe-link")
                try fm.createSymbolicLink(at: link, withDestinationURL: directory.appendingPathComponent("server/Ordner"))
                do { _ = try await CommanderOnlineTools.scan(client, ancestors: [], hidden: true); fatalError("unsafe tool listing accepted") } catch { }
                try fm.removeItem(at: link)
            }
            try await client.createFolder("QA-" + scheme, parent: nil)
            let folder = try await client.children().first { $0.name == "QA-" + scheme }!
            let nested = directory.appendingPathComponent("Tree-" + scheme)
            try fm.createDirectory(at: nested.appendingPathComponent("Child"), withIntermediateDirectories: true)
            try Data("recursive fixture".utf8).write(to: nested.appendingPathComponent("Child/Nested.txt"))
            try await client.uploadTree(nested, parent: folder.id)
            let remoteTree = try await client.children(of: folder.id).first { $0.name == nested.lastPathComponent }!
            let treeCopy = try await client.downloadTree(remoteTree)
            check(try Data(contentsOf: treeCopy.appendingPathComponent("Child/Nested.txt")) == Data("recursive fixture".utf8), "recursive folder roundtrip")
            try? fm.removeItem(at: treeCopy.deletingLastPathComponent())
            let scan = try await CommanderOnlineTools.scan(client, ancestors: [folder], hidden: false)
            check(scan.contains { $0.path == nested.lastPathComponent + "/Child/Nested.txt" && $0.ancestors.count == 3 }, "recursive online search paths")
            let resolved = try await CommanderOnlineTools.resolve("/" + folder.name + "/" + remoteTree.name, client: client)
            check(resolved.last?.id == remoteTree.id, "editable search path")
            var expectedContent = try RemoteContent.snapshot(nested); expectedContent.removeValue(forKey: "")
            check(try await CommanderOnlineTools.content(client, ancestors: resolved, hidden: false) == expectedContent, "online content comparison manifest")
            do { try await client.move(remoteTree, parent: remoteTree.id, name: nil); fatalError("cycle allowed") } catch { }
            do { try await client.recycle(remoteTree); fatalError("nonempty folder was removed") } catch { }
            let treeSnapshot = try await client.remoteSnapshot(remoteTree)
            try await client.recycleUnchanged(remoteTree, snapshot: treeSnapshot)
            check(try await client.remoteSnapshot(client.metadata(remoteTree.id)) == treeSnapshot, "recoverable whole-folder move")
            let child = try await client.children(of: remoteTree.id).first!
            let leaf = try await client.children(of: child.id).first!
            try await client.recycle(leaf)
            try await client.recycle(client.metadata(child.id))
            try await client.recycle(client.metadata(remoteTree.id))
            let local = directory.appendingPathComponent("Unicode ä file-" + scheme + ".txt")
            try Data("uploaded data \(scheme)\n".utf8).write(to: local)
            try await client.upload(local, parent: folder.id)
            var uploaded = try await client.children(of: folder.id).first!
            let verified = try await client.download(uploaded)
            check(try Data(contentsOf: verified) == Data(contentsOf: local), "upload readback")
            try? fm.removeItem(at: verified.deletingLastPathComponent())
            do { try await client.upload(local, parent: folder.id); fatalError("collision was overwritten") } catch { }
            let rule = ["Tool-[C][E]", "", "", "1", "3"]
            let toolPlan = try await CommanderOnlineTools.renamePlan(client, parent: folder.id, selected: [uploaded], fields: rule)
            check(toolPlan.first?.name == "Tool-001.txt", "online multi-rename preview")
            let renameSource = directory.appendingPathComponent("server/" + folder.name + "/" + uploaded.name)
            let renameBytes = try Data(contentsOf: renameSource)
            try (renameBytes + Data([65])).write(to: renameSource)
            do { _ = try await CommanderOnlineTools.rename(client, plan: toolPlan, didRename: { _ in fatalError("stale rename logged") }); fatalError("stale preview applied") } catch { }
            try renameBytes.write(to: renameSource)
            uploaded = try await client.metadata(uploaded.id)
            let freshPlan = try await CommanderOnlineTools.renamePlan(client, parent: folder.id, selected: [uploaded], fields: rule)
            var notified = 0
            check(try await CommanderOnlineTools.rename(client, plan: freshPlan, didRename: { _ in notified += 1 }) == 1 && notified == 1, "online multi-rename and audit callback")
            try await client.rename(client.metadata(uploaded.id), to: uploaded.name)
            let noOp = try await CommanderOnlineTools.renamePlan(client, parent: folder.id, selected: [try await client.metadata(uploaded.id)], fields: ["[N][E]", "", "", "1", "3"])
            check(try await CommanderOnlineTools.rename(client, plan: noOp, didRename: { _ in fatalError("no-op audited as mutation") }) == 0, "online no-op rename")
            try await client.rename(uploaded, to: "Renamed ä.txt")
            let renamed = try await client.metadata(uploaded.id)
            check(renamed.name == "Renamed ä.txt", "stable identity after rename")
            let second = RemoteFileClient(connection, transport: { id, connection, password, operation, path, destination, local, completion in
                bridge.remoteOperation(id, connection: connection, password: password, operation: operation, path: path,
                    destination: destination, localURL: local, completion: completion)
            }, password: { "test-only-password" })
            try await second.move(renamed, parent: nil, name: "Moved-" + scheme + ".txt")
            let moved = try await client.metadata(uploaded.id)
            check(moved.name == "Moved-" + scheme + ".txt", "cross-pane rename identity")
            let snapshot = try await client.remoteSnapshot(moved)
            let sourceOnServer = directory.appendingPathComponent("server").appendingPathComponent(moved.name)
            let originalBytes = try Data(contentsOf: sourceOnServer)
            try Data(originalBytes.reversed()).write(to: sourceOnServer)
            do { try await client.recycleUnchanged(moved, snapshot: snapshot); fatalError("changed source removed") } catch { }
            check(fm.fileExists(atPath: sourceOnServer.path), "changed source retained")
            try originalBytes.write(to: sourceOnServer)
            var failVerification = true
            let interrupted = RemoteFileClient(connection, transport: { id, connection, password, operation, path, destination, local, completion in
                if failVerification && operation == "download" && path.contains(".OpenCommander-Recovery-") {
                    failVerification = false
                    completion(nil, RemoteConnection.failure("remote_unavailable")); return
                }
                bridge.remoteOperation(id, connection: connection, password: password, operation: operation, path: path, destination: destination, localURL: local, completion: completion)
            }, password: { "test-only-password" })
            do { try await interrupted.recycleUnchanged(moved, snapshot: snapshot); fatalError("failed verification reported success") } catch { }
            check(fm.fileExists(atPath: sourceOnServer.path), "failed archive verification restores source path")
            check(try Data(contentsOf: sourceOnServer) == originalBytes, "rollback preserves original content")
            let targetProfile = RemoteConnection(name: "Cross-server", scheme: "ftp", host: "127.0.0.1", port: settings["ftp"] as! Int,
                user: "fixture", root: "/Ordner", keyPath: "")
            let target = RemoteFileClient(targetProfile, transport: { id, connection, password, operation, path, destination, local, completion in
                bridge.remoteOperation(id, connection: connection, password: password, operation: operation, path: path, destination: destination, localURL: local, completion: completion)
            }, password: { "test-only-password" })
            let crossSource = try await client.downloadTree(moved)
            defer { try? fm.removeItem(at: crossSource.deletingLastPathComponent()) }
            try await target.uploadTree(crossSource, parent: nil)
            let crossItem = try await target.children().first { $0.name == moved.name }!
            check(try await target.remoteSnapshot(crossItem) == snapshot, "cross-connection destination hash")
            print("Verified source snapshot \(mode)"); fflush(stdout)
            try await client.recycleUnchanged(moved, snapshot: snapshot)
            print("Quarantined source \(mode)"); fflush(stdout)
            check(client.moveBackupLocation != nil, "recoverable source move")
            check(!(try await client.children()).contains { $0.name == moved.name }, "original path removed")
            let backup = try await client.metadata(moved.id)
            let backupFile = try await client.download(backup)
            check(try RemoteContent.snapshot(backupFile) == snapshot, "backup content unchanged")
            try? fm.removeItem(at: backupFile.deletingLastPathComponent())
            try await client.recycle(backup)
            try await target.recycle(crossItem)
            try await client.recycle(client.metadata(folder.id))
            check(progressEvents.contains { $0.0 == "remote_download_phase" && $0.1 == $0.2 && $0.2 > 0 }, "download byte progress completed after verification")
            check(progressEvents.contains { $0.0 == "remote_verify_phase" && $0.1 == $0.2 && $0.2 > 0 }, "upload verification byte progress")
            if scheme == "sftp" {
                var bad = connection
                bad.trustedHostKeys = settings["wrongHostKeys"] as? String
                do {
                    let encoded = try JSONEncoder().encode(bad)
                    let _: Data = try await withCheckedThrowingContinuation { continuation in
                        bridge.remoteOperation(UUID().uuidString, connection: encoded, password: nil, operation: "list", path: "/", destination: nil, localURL: nil) { data, error in
                            if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: data ?? Data()) }
                        }
                    }
                    fatalError("changed SSH host key accepted")
                } catch { }
                if mode == "sftp-password" {
                    let wrongPassword = RemoteFileClient(connection, transport: { id, connection, password, operation, path, destination, local, completion in
                        bridge.remoteOperation(id, connection: connection, password: password, operation: operation, path: path, destination: destination, localURL: local, completion: completion)
                    }, password: { "wrong-password" })
                    do { _ = try await wrongPassword.children(); fatalError("wrong password accepted") } catch { }
                }
                let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                try? fm.removeItem(at: support.appendingPathComponent("OpenCommander/SSH/" + connection.id + "-known_hosts"))
            }
            if scheme == "ftps" {
                for invalid in ["untrusted", "hostname", "downgrade"] {
                    var bad = connection
                    if invalid == "untrusted" { bad.tlsCAPath = nil }
                    if invalid == "hostname" { bad.host = "localhost" }
                    if invalid == "downgrade" { bad.port = settings["ftp"] as! Int }
                    let rejected = RemoteFileClient(bad, transport: { id, connection, password, operation, path, destination, local, completion in
                        bridge.remoteOperation(id, connection: connection, password: password, operation: operation, path: path, destination: destination, localURL: local, completion: completion)
                    }, password: { "test-only-password" })
                    do { _ = try await rejected.children(); fatalError("TLS \(invalid) accepted") } catch { }
                }
            }
            let cancelledClient = RemoteFileClient(connection, transport: { id, connection, password, operation, path, destination, local, completion in
                bridge.cancelRemoteOperation(id)
                bridge.remoteOperation(id, connection: connection, password: password, operation: operation, path: path, destination: destination, localURL: local, completion: completion)
            }, password: { "test-only-password" })
            do { _ = try await cancelledClient.children(); fatalError("cancelled operation executed") }
            catch is CancellationError { }
            catch { fatalError("cancellation lost: \(error)") }
            if scheme == "sftp" {
                let slow = directory.appendingPathComponent("server/Cancel-transfer.txt")
                try Data(repeating: 65, count: 1024 * 1024).write(to: slow)
                let slowItem = try await client.children().first { $0.name == "Cancel-transfer.txt" }!
                let transfer = Task { try await client.download(slowItem) }
                try await Task.sleep(nanoseconds: 300_000_000)
                transfer.cancel()
                do { _ = try await transfer.value; fatalError("in-flight transfer did not cancel") }
                catch is CancellationError { }
                catch { fatalError("in-flight cancellation lost: \(error)") }
                check(try Data(contentsOf: slow).count == 1024 * 1024, "cancel retains server source")
                try fm.removeItem(at: slow)
            }
            print("PASS live \(mode): transfers, byte progress, recursive search/path/case, content comparison, multi-rename preview/staleness/audit, recovery moves, rollback, cancellation and authentication protection")
        }
    }
}
