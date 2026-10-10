import Foundation

#if targetEnvironment(macCatalyst) || os(macOS)
@objc(OpenCommanderDesktopBridgeProtocol)
protocol DesktopBridgeProtocol {
    init()
    func setFolderApplication(_ application: URL, completion: @escaping (NSError?) -> Void)
    func openFile(_ url: URL, application: URL?, completion: @escaping (Bool, NSError?) -> Void)
    func chooseApplication(for url: URL, title: String, completion: @escaping (Bool, NSError?) -> Void)
    func unmountedVolumes(completion: @escaping ([[String: String]], NSError?) -> Void)
    func mountVolume(_ identifier: String, completion: @escaping (NSError?) -> Void)
    func isEjectableVolume(_ url: URL) -> Bool
    func ejectVolume(_ url: URL, completion: @escaping (NSError?) -> Void)
    func installedCloudApplications() -> [[String: String]]
    func chooseArchiveDestination(name: String, directory: URL, title: String, completion: @escaping (URL?) -> Void)
    func chooseLocation(title: String, completion: @escaping (URL?) -> Void)
    func remoteOperation(_ requestID: String, connection: Data, password: String?, operation: String,
                         path: String, destination: String?, localURL: URL?, completion: @escaping (Data?, NSError?) -> Void)
    func cancelRemoteOperation(_ requestID: String)
    func remoteHostKeys(_ connection: Data, completion: @escaping (String?, NSError?) -> Void)
}
#endif

#if targetEnvironment(macCatalyst)
enum DesktopBridge {
    static let shared: DesktopBridgeProtocol? = {
        guard let plugins = Bundle.main.builtInPlugInsURL,
              let bundle = Bundle(url: plugins.appendingPathComponent("OpenCommanderMacBridge.bundle")),
              bundle.load(), let type = bundle.principalClass as? DesktopBridgeProtocol.Type else { return nil }
        return type.init()
    }()
}
#endif
