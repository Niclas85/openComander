import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--reset-file-access-onboarding") {
            UserDefaults.standard.removeObject(forKey: "ios_file_access_onboarding_v2_shown")
        }
        if ProcessInfo.processInfo.arguments.contains("--app-review-fixtures") {
            prepareAppReviewFixtures()
        }
#endif
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = ViewController()
        window?.makeKeyAndVisible()
#if targetEnvironment(macCatalyst)
        if let windowScene = window?.windowScene {
            windowScene.title = "OpenCommander"
            windowScene.sizeRestrictions?.minimumSize = CGSize(width: 900, height: 600)
        }
#endif
        return true
    }

#if DEBUG
    private func prepareAppReviewFixtures() {
        let fileManager = FileManager.default
        UserDefaults.standard.set("en", forKey: "language")
        guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let source = documents.appendingPathComponent("Source", isDirectory: true)
        let notes = source.appendingPathComponent("Notes", isDirectory: true)
        let target = documents.appendingPathComponent("Target", isDirectory: true)
        let dragMe = documents.appendingPathComponent("DragMe", isDirectory: true)
        let dropHere = documents.appendingPathComponent("DropHere", isDirectory: true)
        try? fileManager.createDirectory(at: notes, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: dragMe, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: dropHere, withIntermediateDirectories: true)
        try? Data("OpenCommander physical iPhone review test\n".utf8)
            .write(to: source.appendingPathComponent("Welcome.txt"), options: .atomic)
        try? Data("Copy, move, ZIP and undo verified.\n".utf8)
            .write(to: notes.appendingPathComponent("Checklist.txt"), options: .atomic)
        try? Data("Drop files here.\n".utf8)
            .write(to: target.appendingPathComponent("Existing.txt"), options: .atomic)
        try? Data("Drop target.\n".utf8)
            .write(to: dropHere.appendingPathComponent("Destination.txt"), options: .atomic)
        try? Data("Drag-and-drop copy verified on physical iPhone.\n".utf8)
            .write(to: dragMe.appendingPathComponent("Proof.txt"), options: .atomic)
        try? fileManager.removeItem(at: dropHere.appendingPathComponent("DragMe"))
        try? fileManager.removeItem(at: documents.appendingPathComponent("Source.zip"))
    }
#endif

}
