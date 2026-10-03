import Foundation

let fm = FileManager.default
let fixture = fm.temporaryDirectory.appendingPathComponent("OpenCommander-SafetyTests-\(UUID().uuidString)")
try fm.createDirectory(at: fixture, withIntermediateDirectories: false)
defer { try? fm.removeItem(at: fixture) }
func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { fatalError("FAIL: " + message) }
}
func write(_ name: String, _ content: String) throws -> URL {
    let url = fixture.appendingPathComponent(name)
    try Data(content.utf8).write(to: url)
    return url
}
func contents(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
func mustFail(_ label: String, _ action: () throws -> Void) {
    do { try action(); fatalError("FAIL: expected error: " + label) } catch { }
}

let source = try write("source.txt", "new contents")
let target = try write("target.txt", "old contents")
mustFail("partial copy") {
    _ = try SafeFileOperations.copyReplacing(source: source, destination: target, replace: true, copy: { _, staging in
        try Data("partial".utf8).write(to: staging)
        throw NSError(domain: "InjectedCopyFailure", code: 1)
    })
}
try check(contents(target) == "old contents", "partial copy leaves previous target in place")
try check(contents(source) == "new contents", "partial copy leaves source in place")

mustFail("publication failure") {
    _ = try SafeFileOperations.copyReplacing(source: source, destination: target, replace: true,
                                             publish: { _, _ in throw NSError(domain: "InjectedPublishFailure", code: 1) })
}
try check(contents(target) == "old contents", "previous target restored after publication failure")

let backup = try SafeFileOperations.copyReplacing(source: source, destination: target, replace: true)
try check(backup != nil, "replacement retains old version")
try check(contents(target) == "new contents", "complete replacement published")
let copyRecord = FileUndoRecord(source: source, destination: target, replacedBackup: backup)
let date = try fm.attributesOfItem(atPath: target.path)[.modificationDate] as! Date
try Data("new CONtents".utf8).write(to: target) // Same size.
try fm.setAttributes([.modificationDate: date], ofItemAtPath: target.path)
mustFail("edited destination") { try copyRecord.undo(move: false) }
try check(contents(target) == "new CONtents", "edited file retained")
try check(contents(backup!) == "old contents", "backup retained after refused undo")

let second = try write("second.txt", "unchanged")
let secondRecord = FileUndoRecord(source: source, destination: second, replacedBackup: nil)
try secondRecord.undo(move: false)
try check(!SafeFileOperations.exists(second), "unchanged copy undone")
try secondRecord.undo(move: false) // Completed records are idempotent during partial batch retries.
try check(secondRecord.completed, "completed record remains completed")
let recoveryFolders = try fm.contentsOfDirectory(at: fixture, includingPropertiesForKeys: nil)
    .filter { $0.lastPathComponent.hasPrefix(".OpenCommanderUndo-") }
try check(recoveryFolders.contains { fm.fileExists(atPath: $0.appendingPathComponent("second.txt").path) },
          "undone copy retained for recovery")

let moved = try write("moved.txt", "moved contents")
let original = fixture.appendingPathComponent("original.txt")
let moveRecord = FileUndoRecord(source: original, destination: moved, replacedBackup: nil)
_ = try write("original.txt", "new file at original path")
mustFail("source conflict") { try moveRecord.undo(move: true) }
try check(contents(original) == "new file at original path", "new source file not overwritten")
try check(contents(moved) == "moved contents", "destination retained on conflict")
try fm.removeItem(at: original)
try moveRecord.undo(move: true)
try check(contents(original) == "moved contents", "move can be undone after conflict is resolved")

let retryTarget = try write("retry.txt", "copy")
let retryBackup = fixture.appendingPathComponent("retry-backup.txt")
let retryRecord = FileUndoRecord(source: source, destination: retryTarget, replacedBackup: retryBackup)
mustFail("missing backup") { try retryRecord.undo(move: false) }
_ = try write("retry-backup.txt", "previous")
try retryRecord.undo(move: false)
try check(contents(retryTarget) == "previous", "retry resumes restoration without repeating destination removal")

let folder = fixture.appendingPathComponent("folder")
try fm.createDirectory(at: folder, withIntermediateDirectories: false)
let folderRecord = FileUndoRecord(source: source, destination: folder, replacedBackup: nil)
try Data("added".utf8).write(to: folder.appendingPathComponent("new.txt"))
mustFail("new directory child") { try folderRecord.undo(move: false) }
try check(SafeFileOperations.exists(folder.appendingPathComponent("new.txt")), "added child retained")
print("PASS: staged copy failure, replacement backup, same-size edits, copy undo, recovery, source conflict, move undo, partial retry and added children")

let persistedTarget = try write("persisted.txt", "saved")
let persisted = FileUndoRecord(source: source, destination: persistedTarget, replacedBackup: nil)
let reloaded = try JSONDecoder().decode(FileUndoRecord.self, from: JSONEncoder().encode(persisted))
try check(reloaded.createdAt == persisted.createdAt, "history timestamp survives restart")
try reloaded.undo(move: false)
try check(!SafeFileOperations.exists(persistedTarget), "saved undo remains operational")
let guardedTarget = try write("persisted-guard.txt", "before")
let guarded = FileUndoRecord(source: source, destination: guardedTarget, replacedBackup: nil)
let guardedReloaded = try JSONDecoder().decode(FileUndoRecord.self, from: JSONEncoder().encode(guarded))
try Data("after!".utf8).write(to: guardedTarget)
mustFail("persisted snapshot guard") { try guardedReloaded.undo(move: false) }
try check(contents(guardedTarget) == "after!", "persisted history preserves external changes")
print("PASS: Codable history roundtrip and post-restart conflict protection")

let cancellation = FileOperationCancellation()
let cancelTarget = try write("cancel-target.txt", "old destination")
cancellation.cancel()
mustFail("cancel before transfer") {
    _ = try SafeFileOperations.copyReplacing(source: source, destination: cancelTarget, replace: true, copy: cancellation.copy)
}
try check(contents(cancelTarget) == "old destination", "cancel keeps destination")
cancellation.reset()
let nativeCopy = fixture.appendingPathComponent("native-copy.txt")
_ = try SafeFileOperations.copyReplacing(source: source, destination: nativeCopy, replace: false, copy: cancellation.copy)
try check(contents(nativeCopy) == contents(source), "native cancellable copy preserves content")
mustFail("cancel after staging before publish") {
    _ = try SafeFileOperations.copyReplacing(source: source, destination: cancelTarget, replace: true, copy: { from, to in
        try cancellation.copy(from, to)
        cancellation.cancel()
        try cancellation.check()
    })
}
try check(contents(cancelTarget) == "old destination", "cancelled staging does not displace target")
print("PASS: native copy and cancellation preserves existing destination")

cancellation.reset()
let nativeFolder = fixture.appendingPathComponent("native-folder")
let nested = folder.appendingPathComponent("nested")
try fm.createDirectory(at: nested, withIntermediateDirectories: false)
try Data("nested content".utf8).write(to: nested.appendingPathComponent("child.txt"))
try fm.createSymbolicLink(atPath: folder.appendingPathComponent("outside-link").path, withDestinationPath: source.path)
try fm.createSymbolicLink(atPath: folder.appendingPathComponent("dangling-link").path, withDestinationPath: "/nonexistent-opencommander-fixture")
_ = try SafeFileOperations.copyReplacing(source: folder, destination: nativeFolder, replace: false, copy: cancellation.copy)
try check(contents(nativeFolder.appendingPathComponent("nested/child.txt")) == "nested content", "recursive native copy")
try check(fm.destinationOfSymbolicLink(atPath: nativeFolder.appendingPathComponent("outside-link").path) == source.path, "copy does not dereference links")
try check(SafeFileOperations.exists(nativeFolder.appendingPathComponent("dangling-link")), "dangling link copied")
let scannedBytes = try BoundedFolderSize.bytes(at: folder)
try check(scannedBytes == Int64("added".utf8.count + "nested content".utf8.count), "folder scan skips symlink content (actual: \(scannedBytes))")
mustFail("bounded folder entry limit") { _ = try BoundedFolderSize.bytes(at: folder, maximumEntries: 1) }
mustFail("bounded folder timeout") { _ = try BoundedFolderSize.bytes(at: folder, timeout: -1) }
print("PASS: recursive native copy, symlinks and bounded folder metadata")

for name in ["../escape", "/absolute", "a/../escape", "a/./b", "a//b", "C:/escape", "a\\b", "nul\0name", ""] {
    mustFail("unsafe ZIP name \(name)") {
        var limits = SafeArchiveLimits()
        try limits.include(path: name, size: 1, symbolicLink: false)
    }
}
mustFail("ZIP symlink") {
    var limits = SafeArchiveLimits()
    try limits.include(path: "link", size: 1, symbolicLink: true)
}
mustFail("case insensitive ZIP duplicate") {
    var limits = SafeArchiveLimits()
    try limits.include(path: "Folder/", size: 0, symbolicLink: false)
    try limits.include(path: "folder", size: 0, symbolicLink: false)
}
mustFail("ZIP byte limit") {
    var limits = SafeArchiveLimits()
    try limits.include(path: "big", size: SafeArchiveLimits.maximumBytes, symbolicLink: false)
    try limits.include(path: "extra", size: 1, symbolicLink: false)
}
print("PASS: ZIP traversal, duplicate, symlink and expanded-size safety limits")
