import Foundation
import MobileCoreServices
import UniformTypeIdentifiers
import ZIPFoundation

class FileEntry: Hashable, Equatable {
    let url: URL
    private let _parent: FileEntry?
    let zipPath: String?
    let zipDirectory: Bool
    let zipSize: Int64
    let zipModified: Int64
    let isUpButton: Bool

    var parent: FileEntry? {
        if let p = _parent { return p }
        if zipPath != nil {
            // ZIP parent logic could be added here if needed
        }
        if url.path == "/" { return nil }
        return FileEntry(url: url.deletingLastPathComponent(), parent: nil)
    }


    init(url: URL, parent: FileEntry?, zipPath: String? = nil, zipDirectory: Bool = false, zipSize: Int64 = 0, zipModified: Int64 = 0, isUpButton: Bool = false) {
        self.url = url
        self._parent = parent
        self.zipPath = zipPath
        self.zipDirectory = zipDirectory
        self.zipSize = zipSize
        self.zipModified = zipModified
        self.isUpButton = isUpButton
    }

    static func == (lhs: FileEntry, rhs: FileEntry) -> Bool {
        return lhs.key() == rhs.key()
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(key())
    }

    func key() -> String {
        if let zipPath = zipPath {
            return physicalKey() + "!/" + zipPath
        }
        if isZipArchive() {
            return physicalKey() + "!/"
        }
        return physicalKey()
    }

    func physicalKey() -> String {
        return url.path
    }

    func name() -> String {
        if isUpButton { return ".." }
        if let zipPath = zipPath {
            let normalized = zipPath.hasSuffix("/") ? String(zipPath.dropLast()) : zipPath
            if let slash = normalized.lastIndex(of: "/") {
                return String(normalized[normalized.index(after: slash)...])
            }
            return normalized
        }
        if url.path == "/" {
            return (try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? "Macintosh HD"
        }
        return url.lastPathComponent
    }

    func mimeType() -> String {
        if isDirectoryLike() {
            return "resource/folder"
        }
        let ext = (zipPath != nil ? (name() as NSString).pathExtension : url.pathExtension).lowercased()
        if let uti = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, ext as CFString, nil)?.takeRetainedValue() {
            if let mime = UTTypeCopyPreferredTagWithClass(uti, kUTTagClassMIMEType)?.takeRetainedValue() {
                return mime as String
            }
        }
        return "application/octet-stream"
    }

    func isPhysical() -> Bool {
        return zipPath == nil
    }

    func isPhysicalDirectory() -> Bool {
        if zipPath != nil { return false }
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return isDirectory.boolValue
    }

    func isZipArchive() -> Bool {
        return zipPath == nil && !isPhysicalDirectory() && name().lowercased().hasSuffix(".zip")
    }

    func isZipEntry() -> Bool {
        return zipPath != nil
    }

    func isDirectoryLike() -> Bool {
        return isUpButton || isPhysicalDirectory() || isZipArchive() || (zipPath != nil && zipDirectory)
    }

    func canWriteDirectory() -> Bool {
        if !isPhysicalDirectory() {
            return false
        }
        if (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true {
            return false
        }
        return FileManager.default.isWritableFile(atPath: url.path)
    }

    func displayPath() -> String {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        // Device URLs may use either /var or /private/var for the same container.
        let documentsPath = documents.resolvingSymlinksInPath().path
        let resolvedPath = url.resolvingSymlinksInPath().path
        let physicalPath: String
        if resolvedPath == documentsPath {
            physicalPath = "/Documents"
        } else if resolvedPath.hasPrefix(documentsPath + "/") {
            physicalPath = "/Documents" + String(resolvedPath.dropFirst(documentsPath.count))
        } else {
            physicalPath = url.path
        }
        if let zipPath = zipPath {
            return physicalPath + "!/" + zipPath
        }
        if isZipArchive() {
            return physicalPath + "!/"
        }
        return physicalPath
    }

    func size() -> Int64 {
        if let _ = zipPath {
            return zipSize
        }
        do {
            let attr = try FileManager.default.attributesOfItem(atPath: url.path)
            return attr[.size] as? Int64 ?? 0
        } catch {
            return 0
        }
    }

    func modified() -> Int64 {
        if let _ = zipPath {
            return zipModified
        }
        do {
            let attr = try FileManager.default.attributesOfItem(atPath: url.path)
            if let date = attr[.modificationDate] as? Date {
                return Int64(date.timeIntervalSince1970 * 1000)
            }
        } catch {}
        return 0
    }

    func children(directoriesOnly: Bool) -> [FileEntry] {
        if isZipArchive() || isZipEntry() {
            return zipChildren(directoriesOnly: directoriesOnly)
        }
        
        var entries: [FileEntry] = []
        do {
            let options: FileManager.DirectoryEnumerationOptions = UserDefaults.standard.bool(forKey: "show_hidden_files") ? [] : .skipsHiddenFiles
            let urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: options)
            for childUrl in urls {
                let entry = FileEntry(url: childUrl, parent: self)
                if directoriesOnly && !entry.isDirectoryLike() {
                    continue
                }
                entries.append(entry)
            }
        } catch {
            print("Error reading directory: \(error)")
        }
        
        // Sort like Android: directories first, then alphabetically
        entries.sort { a, b in
            if a.isDirectoryLike() && !b.isDirectoryLike() { return true }
            if !a.isDirectoryLike() && b.isDirectoryLike() { return false }
            return a.name().localizedStandardCompare(b.name()) == .orderedAscending
        }
        return entries
    }

    func contentBytes() -> Int64 {
        if isZipEntry() { return zipSize }
        if isZipArchive() {
            guard let archive = Archive(url: url, accessMode: .read) else { return 0 }
            return archive.reduce(Int64(0)) { $0 + Int64($1.uncompressedSize) }
        }
        if !isPhysicalDirectory() { return size() }
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let child as URL in enumerator {
            let values = try? child.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    func materializedURLForOpening() throws -> URL {
        guard let zipPath else { return url }
        guard !zipDirectory, let archive = Archive(url: url, accessMode: .read),
              let item = archive.first(where: { $0.path == zipPath }) else {
            throw NSError(domain: "OpenCommander", code: 2, userInfo: [NSLocalizedDescriptionKey: "ZIP entry is unavailable"])
        }
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenCommanderPreview", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let output = outputDirectory.appendingPathComponent(name())
        try? FileManager.default.removeItem(at: output)
        try archive.extract(item, to: output)
        return output
    }

    private func zipChildren(directoriesOnly: Bool) -> [FileEntry] {
        guard let archive = Archive(url: url, accessMode: .read) else { return [] }
        var base = zipPath ?? ""
        if !base.isEmpty && !base.hasSuffix("/") { base += "/" }

        struct ZipChild {
            var isDirectory: Bool
            var size: Int64
        }
        var children: [String: ZipChild] = [:]
        for item in archive {
            guard item.path.hasPrefix(base) else { continue }
            let remainder = String(item.path.dropFirst(base.count))
            guard !remainder.isEmpty else { continue }
            let parts = remainder.split(separator: "/", omittingEmptySubsequences: true)
            guard let first = parts.first else { continue }
            let childName = String(first)
            let childPath = base + childName
            let directory = parts.count > 1 || item.type == .directory || remainder.hasSuffix("/")
            let childSize = directory ? 0 : Int64(item.uncompressedSize)
            if var existing = children[childName] {
                existing.isDirectory = existing.isDirectory || directory
                existing.size = max(existing.size, childSize)
                children[childName] = existing
            } else {
                children[childName] = ZipChild(isDirectory: directory, size: childSize)
            }
            _ = childPath
        }

        return children.compactMap { name, child in
            if directoriesOnly && !child.isDirectory { return nil }
            return FileEntry(
                url: url,
                parent: self,
                zipPath: base + name + (child.isDirectory ? "/" : ""),
                zipDirectory: child.isDirectory,
                zipSize: child.size,
                zipModified: 0
            )
        }.sorted { a, b in
            if a.isDirectoryLike() != b.isDirectoryLike() { return a.isDirectoryLike() }
            return a.name().localizedStandardCompare(b.name()) == .orderedAscending
        }
    }
}
