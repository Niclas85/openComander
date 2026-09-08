import Foundation
import UniformTypeIdentifiers

func check(_ value: Bool) { precondition(value) }

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("OpenCommander-DropTests-\(UUID().uuidString)", isDirectory: true)
try fm.createDirectory(at: root, withIntermediateDirectories: false)
defer { try? fm.removeItem(at: root) }
let source = root.appendingPathComponent("Grüsse-文件.txt")
let bytes = Data("external drag payload\n".utf8)
try bytes.write(to: source)
let folder = root.appendingPathComponent("Folder", isDirectory: true)
try fm.createDirectory(at: folder, withIntermediateDirectories: false)
try bytes.write(to: folder.appendingPathComponent("child.txt"))

func loaded(_ providers: [NSItemProvider]) throws -> FileDropBatch {
    var result: Result<FileDropBatch, Error>?
    FileDropTransfer.load(providers) { result = $0 }
    let deadline = Date(timeIntervalSinceNow: 10)
    while result == nil && Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
    guard let result else { fatalError("Item provider test timed out") }
    return try result.get()
}

let exported = FileDropTransfer.provider(for: source)
precondition(FileDropTransfer.canLoad(exported))
precondition(exported.hasRepresentationConforming(toTypeIdentifier: UTType.plainText.identifier, fileOptions: .openInPlace))
let batch = try loaded([exported, FileDropTransfer.provider(for: folder), exported])
defer { batch.releaseResources() }
precondition(batch.items.count == 2 && batch.items.allSatisfy(\.isOriginal))
try check(Data(contentsOf: batch.items[0].url) == bytes)
precondition(fm.fileExists(atPath: batch.items[1].url.appendingPathComponent("child.txt").path))
print("PASS original file/folder export and import, Unicode, stable order, duplicate removal")

let promise = NSItemProvider()
promise.suggestedName = "../../escape.txt"
promise.registerFileRepresentation(forTypeIdentifier: UTType.plainText.identifier, fileOptions: [], visibility: .all) { completion in
    completion(source, false, nil)
    return nil
}
var staged: URL?
do {
    let result = try loaded([promise])
    defer { result.releaseResources() }
    precondition(result.items.count == 1 && !result.items[0].isOriginal)
    staged = result.stagingDirectory
    precondition(!result.items[0].url.lastPathComponent.isEmpty)
    try check(Data(contentsOf: result.items[0].url) == bytes)
    precondition(result.items[0].url.path.hasPrefix(result.stagingDirectory!.path + "/"))
}
precondition(!fm.fileExists(atPath: staged!.path))
try check(Data(contentsOf: source) == bytes)
print("PASS promised file staging, unsafe-name rejection, owned cleanup preserves source")

let directoryPromise = NSItemProvider()
directoryPromise.registerFileRepresentation(forTypeIdentifier: UTType.folder.identifier, fileOptions: [], visibility: .all) { completion in
    completion(folder, false, nil)
    return nil
}
let directoryBatch = try loaded([directoryPromise])
defer { directoryBatch.releaseResources() }
precondition(!directoryBatch.items[0].isOriginal)
try check(Data(contentsOf: directoryBatch.items[0].url.appendingPathComponent("child.txt")) == bytes)
print("PASS promised directories preserve their contents")

let webLink = NSItemProvider(object: URL(string: "https://example.com/")! as NSURL)
precondition(!FileDropTransfer.canLoad(webLink))
let empty = NSItemProvider()
precondition(!FileDropTransfer.canLoad(empty))
let broken = NSItemProvider()
broken.registerFileRepresentation(forTypeIdentifier: UTType.data.identifier, fileOptions: [], visibility: .all) { completion in
    completion(nil, false, FileDropTransfer.error("injected failure"))
    return nil
}
do {
    _ = try loaded([exported, broken])
    fatalError("Expected all-or-nothing preparation failure")
} catch { precondition(fm.fileExists(atPath: source.path)) }
print("PASS web URLs/unsupported providers rejected; partial provider failure preserves originals")
precondition(FileDropTransfer.safeName("photo", fallback: "image.png") == "photo.png")
precondition(FileDropTransfer.safeName("..", fallback: "safe.txt") == "safe.txt")
print("PASS extension preservation and traversal protection")

let rawURL = NSItemProvider()
rawURL.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
    completion(Data(source.absoluteString.utf8), nil)
    return nil
}
let rawBatch = try loaded([rawURL])
defer { rawBatch.releaseResources() }
precondition(rawBatch.items[0].isOriginal)
try check(Data(contentsOf: rawBatch.items[0].url) == bytes)
print("PASS raw external file-URL representation")

let slow = NSItemProvider()
slow.registerFileRepresentation(forTypeIdentifier: UTType.data.identifier, fileOptions: [], visibility: .all) { completion in
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { completion(source, false, nil) }
    return nil
}
var completions = 0
FileDropTransfer.load([slow], timeout: 0.01) { result in
    completions += 1
    if case .success = result { fatalError("Expected timeout") }
}
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
precondition(completions == 1)
try check(Data(contentsOf: source) == bytes)
print("PASS slow-provider timeout, late callback ignored, original preserved")
