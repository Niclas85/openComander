import Foundation

#if targetEnvironment(macCatalyst) || os(macOS)
@objc(OpenCommanderDesktopBridgeProtocol)
protocol DesktopBridgeProtocol {
    init()
    func openFile(_ url: URL, application: URL?, completion: @escaping (Bool, NSError?) -> Void)
    func chooseApplication(for url: URL, title: String, completion: @escaping (Bool, NSError?) -> Void)
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
