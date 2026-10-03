import AppKit
import UniformTypeIdentifiers

/// Native AppKit bundle loaded only by the Mac Catalyst host. Uses public
/// NSWorkspace APIs, the same Launch Services associations as Finder, no shell.
final class DesktopBridge: NSObject, DesktopBridgeProtocol {
    private var applicationPanel: NSOpenPanel?

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

    func ejectVolume(_ url: URL, completion: @escaping (NSError?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            do {
                let values = try url.resourceValues(forKeys: [.volumeURLKey, .volumeIsInternalKey])
                guard url.standardizedFileURL.path.hasPrefix("/Volumes/"),
                      (values.allValues[.volumeURLKey] as? URL)?.standardizedFileURL == url.standardizedFileURL,
                      values.volumeIsInternal != true else { throw CocoaError(.fileWriteNoPermission) }
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                DispatchQueue.main.async { completion(nil) }
            } catch { DispatchQueue.main.async { completion(error as NSError) } }
        }
    }

    func installedCloudApplications() -> [[String: String]] {
        [("Google Drive", "com.google.drivefs"), ("OneDrive", "com.microsoft.OneDrive"),
         ("Dropbox", "com.getdropbox.dropbox"), ("Box", "com.box.desktop")].compactMap { name, identifier in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else { return nil }
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
