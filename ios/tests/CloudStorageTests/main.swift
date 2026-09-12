import Foundation

let fm = FileManager.default
let fixture = fm.temporaryDirectory.appendingPathComponent("OpenCommander-CloudTests-" + UUID().uuidString)
try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: fixture) } // Only this test-owned local fixture.

func directory(_ relative: String) throws -> URL {
    let url = fixture.appendingPathComponent(relative)
    try fm.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: " + message) }
}

let google = try directory("Library/CloudStorage/GoogleDrive-test@example.invalid")
let myDrive = try directory("Library/CloudStorage/GoogleDrive-test@example.invalid/Meine Ablage")
let oneDrive = try directory("Library/CloudStorage/OneDrive-Personal")
_ = try directory("Library/CloudStorage/OneDrive-Company")
_ = try directory("Library/CloudStorage/Dropbox-Personal")
_ = try directory("Library/CloudStorage/AnotherProvider-Account")
_ = try directory("Library/Mobile Documents/com~apple~CloudDocs")
_ = try directory("OneDrive - Legacy Company")
let archived = try directory("Library/CloudStorage/GoogleDrive-test@example.invalid (old)")
try Data().write(to: archived.appendingPathComponent(".drive_fs_ignore_preserved_domain"))
try fm.createSymbolicLink(at: fixture.appendingPathComponent("OneDrive"), withDestinationURL: oneDrive)
try fm.createSymbolicLink(at: fixture.appendingPathComponent("Google Drive"), withDestinationURL: google)
try fm.createSymbolicLink(at: fixture.appendingPathComponent("Library/CloudStorage/BrokenProvider"),
    withDestinationURL: fixture.appendingPathComponent("missing"))
try Data().write(to: fixture.appendingPathComponent("Library/CloudStorage/not-a-folder"))

let locations = HostFileSystem.cloudStorageLocations(in: fixture)
check(locations.count == 8, "all providers, multiple accounts, legacy and iCloud discovered")
check(locations.filter { $0.url == oneDrive.standardizedFileURL }.count == 1, "OneDrive link deduplicated")
check(locations.filter { $0.name.hasPrefix("Google Drive —") }.count == 2, "Google account plus archive")
check(locations.last?.isLocalArchive == true, "preserved domain distinguished and sorted last")
check(locations.filter { $0.isLocalArchive }.count == 1, "only marked domain is archived")
print("PASS discovery: Google Drive, OneDrive multi-account, iCloud, third-party, legacy, links and archives")

check(HostFileSystem.isCloudStorage(myDrive, home: fixture), "Google child recognized")
check(HostFileSystem.isCloudStorage(fixture.appendingPathComponent("OneDrive/child"), home: fixture), "linked child recognized")
check(HostFileSystem.isCloudStorage(fixture.appendingPathComponent("OneDrive - Legacy Company/child"), home: fixture), "legacy recognized")
check(!HostFileSystem.isCloudStorage(fixture.appendingPathComponent("Library/CloudStorageOther"), home: fixture), "path boundary respected")
check(!HostFileSystem.isCloudStorage(fixture.appendingPathComponent("Documents"), home: fixture), "local not mistaken for cloud")
print("PASS cloud path classification and component boundaries")

try Data("fixture, not user content".utf8).write(to: myDrive.appendingPathComponent("Grüße.txt"))
try Data().write(to: myDrive.appendingPathComponent(".hidden"))
let child = myDrive.appendingPathComponent("Ordner")
try fm.createDirectory(at: child, withIntermediateDirectories: false)
let visible = try HostFileSystem.directoryContents(at: myDrive, showHidden: false)
check(visible.count == 2, "visible entries")
check(HostFileSystem.isDirectory(child), "metadata recognizes directory")
check(!HostFileSystem.isDirectory(myDrive.appendingPathComponent("Grüße.txt")), "file is not directory")
let all = try HostFileSystem.directoryContents(at: myDrive, showHidden: true)
check(all.count == 3, "show hidden honored")
let empty = try HostFileSystem.directoryContents(at: child, showHidden: false)
check(empty.isEmpty, "empty directory succeeds")
do {
    _ = try HostFileSystem.directoryContents(at: fixture.appendingPathComponent("missing"), showHidden: false)
    fatalError("FAIL: missing folder was reported as empty")
} catch { print("PASS missing-directory error remains distinguishable from empty") }
print("PASS Unicode listing, metadata, hidden files and empty directory")

// A coordinated write to a synthetic local folder verifies presenter delivery.
let notification = DispatchSemaphore(value: 0)
let observer = CloudDirectoryObserver(url: myDrive) { notification.signal() }
var coordinationError: NSError?
NSFileCoordinator().coordinate(writingItemAt: myDrive, options: [], error: &coordinationError) { coordinatedURL in
    try! Data("observer fixture".utf8).write(to: coordinatedURL.appendingPathComponent("observer.txt"))
}
check(coordinationError == nil, "coordinated fixture access")
var notificationResult = notification.wait(timeout: .now())
let deadline = Date().addingTimeInterval(5)
while notificationResult != .success && Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    notificationResult = notification.wait(timeout: .now())
}
observer.stop()
check(notificationResult == .success, "presenter receives directory change")
print("PASS directory change observer and explicit deregistration")

// Opt-in, READ-ONLY metadata inspection of this Mac; never read file contents,
// recursively scan, create or delete anything in a real cloud folder.
if CommandLine.arguments.contains("--live-read-only") {
    for location in HostFileSystem.cloudStorageLocations(in: HostFileSystem.homeDirectory) {
        let children = try HostFileSystem.directoryContents(at: location.url, showHidden: false)
        let provider = location.name.hasPrefix("Google Drive") ? "Google Drive" : location.name
        print("LIVE \(provider) archive=\(location.isLocalArchive) entries=\(children.count)")
        if provider == "Google Drive", !location.isLocalArchive {
            for child in children where HostFileSystem.isDirectory(child) {
                let nested = try HostFileSystem.directoryContents(at: child, showHidden: false)
                print("LIVE Google Drive top-level directory entries=\(nested.count)")
            }
        }
    }
}
