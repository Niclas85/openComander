import AppKit
import UniformTypeIdentifiers
import Darwin

private final class SSHPasswordBroker {
    let path: String
    private let descriptor: Int32
    private let directory: URL
    private let lock = NSLock()
    private var closed = false
    init(password: String) throws {
        guard password.utf8.count <= 8192, !password.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) else { throw RemoteConnection.failure("remote_invalid") }
        directory = URL(fileURLWithPath: "/tmp/oc-ask-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        path = directory.appendingPathComponent("password.sock").path
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { try? FileManager.default.removeItem(at: directory); throw RemoteConnection.failure("remote_unavailable") }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in destination.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(descriptor, 1) == 0 else {
            Darwin.close(descriptor); try? FileManager.default.removeItem(at: directory); throw RemoteConnection.failure("remote_unavailable")
        }
        let server = descriptor
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { lock.lock(); closed = true; Darwin.close(server); lock.unlock() }
            var waiting = pollfd(fd: server, events: Int16(POLLIN), revents: 0)
            guard poll(&waiting, 1, 30_000) > 0, waiting.revents & Int16(POLLIN) != 0 else { return }
            let client = accept(server, nil, nil); guard client >= 0 else { return }
            defer { Darwin.close(client) }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { return }
            var noSignal: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var secret = Array((password + "\n").utf8)
            defer { secret.withUnsafeMutableBytes { if let base = $0.baseAddress { _ = memset_s(base, $0.count, 0, $0.count) } } }
            secret.withUnsafeBytes { bytes in
                var written = 0
                while written < bytes.count {
                    let count = Darwin.write(client, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                    if count <= 0 { break }; written += count
                }
            }
        }
    }
    func stop() {
        lock.lock(); if !closed { shutdown(descriptor, SHUT_RDWR) }; lock.unlock()
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Native AppKit bundle loaded only by the Mac Catalyst host. Uses public
/// NSWorkspace APIs, the same Launch Services associations as Finder, no shell.
final class DesktopBridge: NSObject, DesktopBridgeProtocol {
    private var applicationPanel: NSOpenPanel?
    private var locationPanel: NSOpenPanel?
    private var archivePanel: NSSavePanel?
    private let remoteLock = NSLock()
    private var remoteTasks: [String: Process] = [:]
    private var cancelledRemote = Set<String>()
    var sshAskPassURL = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("OpenCommanderSSHAskPass")
    func remoteHostKeys(_ connection: Data, completion: @escaping (String?, NSError?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            do {
                let profile = try JSONDecoder().decode(RemoteConnection.self, from: connection); try profile.validate()
                let process = Process(), pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keyscan")
                process.arguments = ["-T", "5", "-p", String(profile.port), "-t", "ed25519,ecdsa,rsa", profile.host]
                process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
                guard process.terminationStatus == 0, data.count < 64 * 1024, let keys = String(data: data, encoding: .utf8) else { throw RemoteConnection.failure("remote_ssh_failed") }
                _ = try RemoteConnection.fingerprints(keys)
                DispatchQueue.main.async { completion(keys, nil) }
            } catch { DispatchQueue.main.async { completion(nil, error as NSError) } }
        }
    }

    func cancelRemoteOperation(_ requestID: String) {
        remoteLock.lock(); cancelledRemote.insert(requestID)
        let task = remoteTasks[requestID]; remoteLock.unlock()
        if task?.isRunning == true { task?.terminate() }
    }

    func remoteOperation(_ requestID: String, connection: Data, password: String?, operation: String,
                         path: String, destination: String?, localURL: URL?, completion: @escaping (Data?, NSError?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let profile = try JSONDecoder().decode(RemoteConnection.self, from: connection)
                try profile.validate()
                guard password?.contains("\0") != true else { throw RemoteConnection.failure("remote_invalid") }
                guard profile.contains(path), destination.map(profile.contains) != false,
                      ["list", "download", "upload", "mkdir", "rename", "delete", "rmdir"].contains(operation) else {
                    throw RemoteConnection.failure("remote_invalid")
                }
                let task = Process(), input = Pipe(), output = Pipe()
                task.standardInput = input; task.standardOutput = output
                task.standardError = FileHandle.nullDevice // never leak authentication or server responses
#if REMOTE_TRANSPORT_TESTS
                task.standardError = FileHandle.standardError
#endif
                var payload = ""
                var passwordBroker: SSHPasswordBroker?
                defer { passwordBroker?.stop() }
                if profile.scheme == "sftp" {
                    task.executableURL = URL(fileURLWithPath: "/usr/bin/sftp")
                    // No shell, no user ssh_config hooks, no implicit host-key acceptance.
                    // OpenSSH uses the first value: set BatchMode before -b adds its default.
                    task.arguments = ["-o", "BatchMode=\(profile.passwordAuthentication == true ? "no" : "yes")", "-F", "/dev/null", "-b", "-", "-P", String(profile.port),
                        "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=15",
                        "-o", "IdentitiesOnly=\(profile.keyPath.isEmpty ? "no" : "yes")", "-o", "ForwardAgent=no"]
                    if !profile.keyPath.isEmpty { task.arguments! += ["-i", profile.keyPath] }
                    if profile.passwordAuthentication == true {
                        guard let password, !password.isEmpty, let helper = self.sshAskPassURL,
                              FileManager.default.isExecutableFile(atPath: helper.path) else { throw RemoteConnection.failure("remote_password_missing") }
                        passwordBroker = try SSHPasswordBroker(password: password)
                        task.arguments! += ["-o", "PreferredAuthentications=password", "-o", "PubkeyAuthentication=no", "-o", "NumberOfPasswordPrompts=1"]
                    }
                    if let keys = profile.trustedHostKeys {
                        _ = try RemoteConnection.fingerprints(keys)
                        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                            .appendingPathComponent("OpenCommander/SSH", isDirectory: true)
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                        let knownHosts = directory.appendingPathComponent(profile.id + "-known_hosts")
                        try Data(keys.utf8).write(to: knownHosts, options: .atomic)
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: knownHosts.path)
                        let quotedHosts = knownHosts.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                        task.arguments! += ["-o", "UserKnownHostsFile=\"\(quotedHosts)\"", "-o", "GlobalKnownHostsFile=/dev/null"]
                    }
                    let host = profile.host.contains(":") ? "[\(profile.host)]" : profile.host
                    task.arguments! += ["\(profile.user)@\(host)"]
                    func quote(_ value: String) -> String {
                        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
                            .replacingOccurrences(of: "\"", with: "\\\"")
                            .replacingOccurrences(of: "*", with: "\\*")
                            .replacingOccurrences(of: "?", with: "\\?")
                            .replacingOccurrences(of: "[", with: "\\[") + "\""
                    }
                    switch operation {
                    case "list": payload = "ls -lan " + quote(path.hasSuffix("/") ? path : path + "/")
                    case "download", "upload":
                        guard let localURL, localURL.isFileURL, RemoteConnection.validPath(localURL.path) else { throw RemoteConnection.failure("remote_invalid") }
                        payload = operation == "download" ? "get \(quote(path)) \(quote(localURL.path))" : "put \(quote(localURL.path)) \(quote(path))"
                    case "mkdir": payload = "mkdir " + quote(path)
                    case "rename":
                        guard let destination else { throw RemoteConnection.failure("remote_invalid") }
                        payload = "rename \(quote(path)) \(quote(destination))"
                    case "delete": payload = "rm " + quote(path)
                    default: payload = "rmdir " + quote(path)
                    }
                    payload += "\n"
                } else {
                    task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                    task.arguments = ["--disable", "--silent", "--show-error", "--fail", "--globoff",
                        "--connect-timeout", "15", "--max-time", "300", "--noproxy", "*", "--ftp-skip-pasv-ip", "--proto", "=ftp", "--config", "-"]
                    if profile.scheme == "ftps" { task.arguments! += ["--ssl-reqd", "--tlsv1.2"] }
                    if profile.scheme == "ftps", let ca = profile.tlsCAPath { task.arguments! += ["--cacert", ca] }
                    var components = URLComponents()
                    components.scheme = "ftp"; components.host = profile.host; components.port = profile.port
                    // Double slash selects an absolute server path instead of the FTP login home.
                    components.path = "/" + (operation == "list" ? (path.hasSuffix("/") ? path : path + "/") : path)
                    guard let address = components.url?.absoluteString else { throw RemoteConnection.failure("remote_invalid") }
                    func config(_ value: String) -> String {
                        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                            .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r") + "\""
                    }
                    payload = "user = " + config(profile.user + ":" + (password ?? "")) + "\n"
                    switch operation {
                    case "list": task.arguments! += ["--request", "MLSD"]
                    case "download", "upload":
                        guard let localURL, localURL.isFileURL else { throw RemoteConnection.failure("remote_invalid") }
                        task.arguments! += [operation == "download" ? "--output" : "--upload-file", localURL.path]
                    default:
                        task.arguments! += ["--head"]
                        let commands: [String]
                        switch operation {
                        case "mkdir": commands = ["MKD " + path]
                        case "rename":
                            guard let destination else { throw RemoteConnection.failure("remote_invalid") }
                            commands = ["RNFR " + path, "RNTO " + destination]
                        case "delete": commands = ["DELE " + path]
                        default: commands = ["RMD " + path]
                        }
                        for command in commands { task.arguments! += ["--quote", command] }
                        components.path = "/" + profile.root + "/"
                    }
                    task.arguments! += ["--url", ["list", "download", "upload"].contains(operation) ? address : components.url!.absoluteString]
                }
                var environment = ProcessInfo.processInfo.environment
                environment["LC_ALL"] = "en_US.UTF-8"; environment["LANG"] = "en_US.UTF-8"
                if let passwordBroker, let helper = self.sshAskPassURL {
                    environment["SSH_ASKPASS"] = helper.path; environment["SSH_ASKPASS_REQUIRE"] = "force"
                    environment["DISPLAY"] = "OpenCommander"
                    environment["OPENCOMMANDER_ASKPASS_SOCKET"] = passwordBroker.path
                } else {
                    environment.removeValue(forKey: "SSH_ASKPASS"); environment.removeValue(forKey: "SSH_ASKPASS_REQUIRE")
                    environment.removeValue(forKey: "OPENCOMMANDER_ASKPASS_SOCKET")
                }
                task.environment = environment
                self.remoteLock.lock()
                if self.cancelledRemote.contains(requestID) {
                    self.cancelledRemote.remove(requestID); self.remoteLock.unlock(); throw CancellationError()
                }
                self.remoteTasks[requestID] = task
                do { try task.run() } catch { self.remoteTasks.removeValue(forKey: requestID); self.remoteLock.unlock(); throw error }
                self.remoteLock.unlock()
                defer {
                    self.remoteLock.lock(); self.remoteTasks.removeValue(forKey: requestID)
                    self.cancelledRemote.remove(requestID); self.remoteLock.unlock()
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 300) { if task.isRunning { task.terminate() } }
                try input.fileHandleForWriting.write(contentsOf: Data(payload.utf8)); try input.fileHandleForWriting.close()
                var data = Data()
                while let part = try output.fileHandleForReading.read(upToCount: 64 * 1024), !part.isEmpty {
                    data.append(part)
                    if data.count > 16 * 1024 * 1024 { task.terminate(); throw RemoteConnection.failure("remote_limit") }
                }
                task.waitUntilExit()
                self.remoteLock.lock(); let cancelled = self.cancelledRemote.contains(requestID); self.remoteLock.unlock()
                if cancelled { throw CancellationError() }
                guard task.terminationStatus == 0 else { throw RemoteConnection.failure(profile.scheme == "sftp" ? "remote_ssh_failed" : "remote_ftp_failed") }
                if operation == "list" {
                    guard let text = String(data: data, encoding: .utf8) else { throw RemoteConnection.failure("remote_listing") }
                    data = try JSONEncoder().encode(profile.scheme == "sftp" ? RemoteDirectoryItem.sftp(text) : RemoteDirectoryItem.mlsd(text))
                }
                DispatchQueue.main.async { completion(data, nil) }
            } catch { DispatchQueue.main.async { completion(nil, error as NSError) } }
        }
    }

    func chooseArchiveDestination(name: String, directory: URL, title: String, completion: @escaping (URL?) -> Void) {
        guard archivePanel == nil else { completion(nil); return }
        let panel = NSSavePanel()
        archivePanel = panel
        panel.title = title
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = name
        panel.directoryURL = directory
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            self?.archivePanel = nil
            completion(response == .OK ? panel.url : nil)
        }
    }

    func chooseLocation(title: String, completion: @escaping (URL?) -> Void) {
        guard locationPanel == nil else { completion(nil); return }
        let panel = NSOpenPanel()
        locationPanel = panel
        panel.title = title
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            self?.locationPanel = nil
            completion(response == .OK ? panel.url : nil)
        }
    }

    private func diskUtility(_ arguments: [String]) throws -> Data {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        task.arguments = arguments
        let output = Pipe()
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        try task.run()
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
            if task.isRunning { task.terminate() }
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw NSError(domain: "OpenCommander.Volumes", code: Int(task.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "macOS could not complete the volume operation."])
        }
        return data
    }

    private func discoverUnmountedVolumes() throws -> [[String: String]] {
        let data = try diskUtility(["list", "-plist", "external"])
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        var result: [[String: String]] = []
        func visit(_ node: [String: Any]) {
            if let identifier = node["DeviceIdentifier"] as? String,
               let name = node["VolumeName"] as? String, !name.isEmpty,
               (node["MountPoint"] as? String ?? "").isEmpty {
                result.append(["identifier": identifier, "name": name])
            }
            for key in ["Partitions", "APFSVolumes"] {
                (node[key] as? [[String: Any]] ?? []).forEach(visit)
            }
        }
        (plist?["AllDisksAndPartitions"] as? [[String: Any]] ?? []).forEach(visit)
        return result
    }

    func unmountedVolumes(completion: @escaping ([[String: String]], NSError?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            do {
                let volumes = try self.discoverUnmountedVolumes()
                DispatchQueue.main.async { completion(volumes, nil) }
            } catch { DispatchQueue.main.async { completion([], error as NSError) } }
        }
    }

    func mountVolume(_ identifier: String, completion: @escaping (NSError?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            do {
                // Re-discover before acting. No shell, no formatting, no forcing
                // read-write mode, and never target an internal/system device.
                guard identifier.range(of: "^disk[0-9]+(s[0-9]+)*$", options: .regularExpression) != nil,
                      try self.discoverUnmountedVolumes().contains(where: { $0["identifier"] == identifier }) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                _ = try self.diskUtility(["mount", identifier])
                DispatchQueue.main.async { completion(nil) }
            } catch { DispatchQueue.main.async { completion(error as NSError) } }
        }
    }

    func isEjectableVolume(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.volumeURLKey, .volumeIsInternalKey]),
              url.standardizedFileURL.path.hasPrefix("/Volumes/"),
              (values.allValues[.volumeURLKey] as? URL)?.standardizedFileURL == url.standardizedFileURL,
              values.volumeIsInternal != true else { return false }
        // Disk images may omit Foundation's internal-volume flag. Confirm with
        // Disk Arbitration metadata instead of treating an unknown flag as safe.
        guard let data = try? diskUtility(["info", "-plist", url.path]),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              (info["Internal"] as? Bool) == false,
              let mountPoint = info["MountPoint"] as? String,
              URL(fileURLWithPath: mountPoint).standardizedFileURL == url.standardizedFileURL
        else { return false }
        return true
    }

    func ejectVolume(_ url: URL, completion: @escaping (NSError?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            do {
                guard self.isEjectableVolume(url) else { throw CocoaError(.fileWriteNoPermission) }
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                DispatchQueue.main.async { completion(nil) }
            } catch { DispatchQueue.main.async { completion(error as NSError) } }
        }
    }

    func installedCloudApplications() -> [[String: String]] {
        [("Google Drive", ["com.google.drivefs"]),
         ("OneDrive", ["com.microsoft.OneDrive", "com.microsoft.OneDrive-mac"]),
         ("Dropbox", ["com.getdropbox.dropbox"]), ("Box", ["com.box.desktop"])].compactMap { name, identifiers in
            guard let url = identifiers.lazy.compactMap({
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
            }).first else { return nil }
            return ["name": name, "path": url.path]
        }
    }

    func setFolderApplication(_ application: URL, completion: @escaping (NSError?) -> Void) {
        NSWorkspace.shared.setDefaultApplication(at: application, toOpen: .folder) { error in
            DispatchQueue.main.async { completion(error as NSError?) }
        }
    }

    func openFile(_ url: URL, application: URL?, completion: @escaping (Bool, NSError?) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let finished: (NSRunningApplication?, Error?) -> Void = { _, error in
            DispatchQueue.main.async { completion(error == nil, error as NSError?) }
        }
        if let application {
            NSWorkspace.shared.open([url], withApplicationAt: application,
                                    configuration: configuration, completionHandler: finished)
        } else {
            NSWorkspace.shared.open(url, configuration: configuration, completionHandler: finished)
        }
    }

    func chooseApplication(for url: URL, title: String, completion: @escaping (Bool, NSError?) -> Void) {
        guard applicationPanel == nil else { completion(false, nil); return }
        let panel = NSOpenPanel()
        applicationPanel = panel
        panel.title = title
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.begin { [weak self] response in
            self?.applicationPanel = nil
            guard response == .OK, let application = panel.url else { completion(false, nil); return }
            self?.openFile(url, application: application, completion: completion)
        }
    }
}
