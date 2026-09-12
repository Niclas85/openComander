import AppKit
import UniformTypeIdentifiers

/// Native AppKit bundle loaded only by the Mac Catalyst host. Uses public
/// NSWorkspace APIs, the same Launch Services associations as Finder, no shell.
final class DesktopBridge: NSObject, DesktopBridgeProtocol {
    private var applicationPanel: NSOpenPanel?

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
