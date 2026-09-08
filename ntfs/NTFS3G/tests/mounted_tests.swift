// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Darwin
func check(_ condition: Bool) { precondition(condition) }

// Only run inside the private image mount created by test-fskit.sh.
let root = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
precondition(root.lastPathComponent == "mount" && root.deletingLastPathComponent().lastPathComponent.hasPrefix("fskit-fixture."))
var fs = statfs()
precondition(statfs(root.path, &fs) == 0)
let kind = withUnsafePointer(to: &fs.f_fstypename) {
    $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
}
// FSKit exposes the volume's fileSystemTypeName, not the framework name.
precondition(kind == "openntfs", "Expected OpenCommander NTFS mount, got \(kind)")
let mountPoint = withUnsafePointer(to: &fs.f_mntonname) {
    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
}
precondition(URL(fileURLWithPath: mountPoint).resolvingSymlinksInPath() == root, "Test directory must be the mount root")
let fm = FileManager.default
let folder = root.appendingPathComponent("OpenCommander-Test-" + UUID().uuidString)
try fm.createDirectory(at: folder, withIntermediateDirectories: false)
let file = folder.appendingPathComponent("Grüsse-文件.txt")
let payload = Data("OpenCommander → FSKit → NTFS-3G\n".utf8)
try payload.write(to: file)
try check(Data(contentsOf: file) == payload)
let large = folder.appendingPathComponent("large.bin")
let bytes = Data((0..<(2 * 1024 * 1024 + 17)).map { UInt8($0 % 251) })
try bytes.write(to: large)
try check(Data(contentsOf: large) == bytes)
let copy = folder.appendingPathComponent("copy.bin")
try fm.copyItem(at: large, to: copy)
try check(Data(contentsOf: copy) == bytes)
let renamed = folder.appendingPathComponent("renamed.bin")
try fm.moveItem(at: copy, to: renamed)
precondition(!fm.fileExists(atPath: copy.path))
try payload.write(to: renamed, options: .atomic)
try check(Data(contentsOf: renamed) == payload)
try fm.removeItem(at: renamed)
precondition(!fm.fileExists(atPath: renamed.path))
let handle = try FileHandle(forUpdating: large)
try handle.truncate(atOffset: 517)
try handle.synchronize()
try handle.close()
try check(Data(contentsOf: large) == bytes.prefix(517))
print("PASS FSKit mount: Unicode, create, read/write, copy, rename, replace, delete, truncate, fsync")
print("Retained test directory: \(folder.path)")
