import UIKit
import ZIPFoundation

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
        if ProcessInfo.processInfo.arguments.contains("--image-viewer-fixtures") {
            prepareImageViewerFixtures()
        }
        if ProcessInfo.processInfo.arguments.contains("--stale-folder-bookmark-fixture") {
            prepareStaleFolderBookmarkFixture()
        }
        if ProcessInfo.processInfo.arguments.contains("--reset-media-import-fixtures") {
            resetMediaImportFixtures()
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

    private func prepareStaleFolderBookmarkFixture() {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "ios_file_access_onboarding_v2_shown")
        defaults.set(true, forKey: "onboarding_shown")
        defaults.set(Data("not-a-bookmark".utf8), forKey: "folder_bookmark_pane_1")
        defaults.set(Data("not-a-bookmark".utf8), forKey: "folder_bookmark_pane_2")
        defaults.set("/private/unavailable", forKey: "folder_path_pane_1")
        defaults.set("/private/unavailable", forKey: "folder_path_pane_2")
    }

    private func resetMediaImportFixtures() {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        try? FileManager.default.removeItem(at: documents.appendingPathComponent("Media", isDirectory: true))
    }

    private func prepareImageViewerFixtures() {
        let fileManager = FileManager.default
        UserDefaults.standard.set("en", forKey: "language")
        guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let folder = documents.appendingPathComponent("ImageViewerQA", isDirectory: true)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        func png(color: UIColor, text: String) -> Data? {
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 600))
            return renderer.pngData { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 900, height: 600))
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.boldSystemFont(ofSize: 72),
                    .foregroundColor: UIColor.white,
                ]
                let size = (text as NSString).size(withAttributes: attributes)
                (text as NSString).draw(
                    at: CGPoint(x: (900 - size.width) / 2, y: (600 - size.height) / 2),
                    withAttributes: attributes
                )
            }
        }

        let first = folder.appendingPathComponent("01-first.png")
        let second = folder.appendingPathComponent("02-second.png")
        try? png(color: UIColor.systemBlue, text: "FIRST")?.write(to: first, options: .atomic)
        try? png(color: UIColor.systemGreen, text: "SECOND")?.write(to: second, options: .atomic)
        try? Data("not an image".utf8).write(
            to: folder.appendingPathComponent("03-corrupt.png"), options: .atomic)

        let zip = folder.appendingPathComponent("gallery.zip")
        try? fileManager.removeItem(at: zip)
        if let archive = Archive(url: zip, accessMode: .create) {
            try? archive.addEntry(with: first.lastPathComponent, fileURL: first)
            try? archive.addEntry(with: second.lastPathComponent, fileURL: second)
        }
    }
#endif

}
