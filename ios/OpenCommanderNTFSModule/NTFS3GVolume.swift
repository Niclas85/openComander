// SPDX-License-Identifier: GPL-2.0-or-later
// Experimental byte-copy FSKit integration. No kernel-offloaded I/O.
import Foundation
import FSKit
import OpenCommanderNTFS

private final class EngineItem: FSItem {
    var path: String
    let id: FSItem.Identifier
    let inode: UInt64
    init(path: String, inode: UInt64) {
        self.path = path
        self.inode = inode
        self.id = path == "/" ? .rootDirectory : FSItem.Identifier(rawValue: inode + 16)!
        super.init()
    }
}

private final class EngineDirectory {
    var entries: [(String, Bool)] = []
}

final class NTFS3GVolume: FSVolume, FSVolume.Operations, FSVolume.ReadWriteOperations {
    // The entire operation (engine + item cache) runs on this queue, not merely
    // individual C calls. This prevents rename/read and enumeration races.
    private let queue = DispatchQueue(label: "OpenCommander.NTFS3G")
    private let device: FSKitBlockDevice
    private let readOnly: Bool
    private var engine: OpaquePointer?
    private var items: [UInt64: EngineItem] = [:]
    private var generation: UInt64 = 1
    private var closeError: Error?

    deinit {
        // Also release the engine if a failed mount never calls unmount().
        if let engine { _ = nk_umount(engine) }
    }

    init(resource: FSBlockDeviceResource, readOnly: Bool, serial: UInt64) throws {
        self.device = try FSKitBlockDevice(resource: resource)
        self.readOnly = readOnly || !resource.isWritable
        let identifier = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012llX", serial & 0xFFFFFFFFFFFF))!
        super.init(volumeID: FSVolume.Identifier(uuid: identifier), volumeName: FSFileName(string: "OpenCommander NTFS"))
    }

    private func error(_ code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code == 0 ? EIO : code))
    }

    private func check(_ result: Int32) throws {
        if result != 0 { throw error() }
    }

    private func requireItem(_ item: FSItem) throws -> EngineItem {
        guard engine != nil else { throw error(ENXIO) }
        guard let item = item as? EngineItem, items[item.inode] === item else { throw error(ESTALE) }
        return item
    }

    private func childPath(_ directory: EngineItem, _ name: FSFileName) throws -> String {
        guard let name = name.string, !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\0") else { throw error(EINVAL) }
        return directory.path == "/" ? "/\(name)" : "\(directory.path)/\(name)"
    }

    private func stat(_ path: String) throws -> nk_stat {
        var st = nk_stat()
        try check(nk_stat_path(engine, path, &st))
        return st
    }

    private func item(_ path: String) throws -> EngineItem {
        let st = try stat(path)
        if let cached = items[st.inode] { return cached }
        let item = EngineItem(path: path, inode: st.inode)
        items[st.inode] = item
        return item
    }

    private func open() throws {
        if engine != nil { return }
        var io = nk_io()
        io.ctx = Unmanaged.passUnretained(device).toOpaque()
        io.size = Int64(device.size)
        io.readonly = readOnly ? 1 : 0
        io.pread = { ctx, buffer, count, offset in
            guard let ctx, let buffer, count >= 0, offset >= 0, count <= Int64(Int.max) else { return -1 }
            do {
                let device = Unmanaged<FSKitBlockDevice>.fromOpaque(ctx).takeUnretainedValue()
                let data = try device.read(offset: UInt64(offset), length: Int(count))
                data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: data.count)
                return Int64(data.count)
            } catch { return -1 }
        }
        io.pwrite = { ctx, buffer, count, offset in
            guard let ctx, let buffer, count >= 0, offset >= 0, count <= Int64(Int.max) else { return -1 }
            do {
                let device = Unmanaged<FSKitBlockDevice>.fromOpaque(ctx).takeUnretainedValue()
                try device.write(offset: UInt64(offset), data: Data(bytes: buffer, count: Int(count)))
                return count
            } catch { return -1 }
        }
        io.sync = { ctx in
            guard let ctx else { return -1 }
            do {
                try Unmanaged<FSKitBlockDevice>.fromOpaque(ctx).takeUnretainedValue().synchronize()
                return 0
            } catch { return -1 }
        }
        var reason = [CChar](repeating: 0, count: 512)
        guard let handle = nk_mount_io(&io, &reason, reason.count) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno == 0 ? EIO : errno),
                          userInfo: [NSLocalizedDescriptionKey: String(cString: reason)])
        }
        engine = handle
        closeError = nil
    }

    private func close() {
        if let handle = engine {
            if nk_umount(handle) != 0 { closeError = error() }
            engine = nil
            items.removeAll()
        }
    }

    func activate(options: FSTaskOptions) async throws -> FSItem {
        try queue.sync {
            try open()
            var label = [CChar](repeating: 0, count: 1024)
            try check(nk_label(engine, &label, label.count))
            self.name = FSFileName(string: String(cString: label))
            return try item("/")
        }
    }
    func mount(options: FSTaskOptions) async throws { try queue.sync { try open() } }
    func unmount() async { queue.sync { close() } }
    func deactivate(options: FSDeactivateOptions) async throws {
        try queue.sync { close(); if let closeError { throw closeError } }
    }
    func synchronize(flags: FSSyncFlags) async throws {
        try queue.sync { try check(nk_sync(engine)); try device.synchronize() }
    }

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let caps = FSVolume.SupportedCapabilities()
        caps.supportsHardLinks = false
        caps.supportsSymbolicLinks = false
        caps.supportsPersistentObjectIDs = false
        caps.supports64BitObjectIDs = true
        caps.doesNotSupportImmutableFiles = true
        return caps
    }
    var maximumLinkCount: Int { 1 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }
    var volumeStatistics: FSStatFSResult {
        queue.sync {
            let result = FSStatFSResult(fileSystemTypeName: "openntfs")
            var total: Int64 = 0, free: Int64 = 0
            var cluster: Int32 = 4096
            if nk_statvfs(engine, &total, &free, &cluster) == 0 && cluster > 0 {
                result.blockSize = Int(cluster)
                result.ioSize = 1024 * 1024
                result.totalBlocks = UInt64(max(0, total)) / UInt64(cluster)
                result.freeBlocks = UInt64(max(0, free)) / UInt64(cluster)
                result.availableBlocks = result.freeBlocks
            }
            return result
        }
    }

    private func attributes(_ item: EngineItem) throws -> FSItem.Attributes {
        let st = try stat(item.path)
        guard st.inode == item.inode else { throw error(ESTALE) }
        let a = FSItem.Attributes()
        a.type = st.is_dir != 0 ? .directory : st.is_symlink != 0 ? .symlink : .file
        a.mode = st.is_dir != 0 ? 0o040755 : 0o100644
        a.size = UInt64(max(0, st.size)); a.allocSize = UInt64(max(0, st.alloc_size))
        a.fileID = item.id
        a.parentID = item.path == "/" ? .parentOfRoot : try self.item((item.path as NSString).deletingLastPathComponent).id
        a.uid = getuid(); a.gid = getgid(); a.linkCount = 1; a.flags = 0
        a.inhibitKernelOffloadedIO = true
        a.accessTime = timespec(tv_sec: Int(st.atime), tv_nsec: 0)
        a.modifyTime = timespec(tv_sec: Int(st.mtime), tv_nsec: 0)
        a.changeTime = timespec(tv_sec: Int(st.ctime), tv_nsec: 0)
        a.birthTime = timespec(tv_sec: Int(st.btime), tv_nsec: 0)
        return a
    }
    func attributes(_ request: FSItem.GetAttributesRequest, of item: FSItem) async throws -> FSItem.Attributes {
        try queue.sync { try attributes(requireItem(item)) }
    }
    private func apply(_ request: FSItem.SetAttributesRequest, to item: EngineItem) throws {
        if readOnly { throw error(EROFS) }
        if request.isValid(.size) {
            guard request.size <= UInt64(Int64.max) else { throw error(EFBIG) }
            try check(nk_truncate(engine, item.path, Int64(request.size)))
            request.consumedAttributes.insert(.size)
        }
        // Unsupported ownership/time attributes remain unconsumed; never claim
        // that a metadata update persisted when the engine has not applied it.
    }
    func setAttributes(_ request: FSItem.SetAttributesRequest, on item: FSItem) async throws -> FSItem.Attributes {
        try queue.sync {
            let item = try requireItem(item)
            try apply(request, to: item)
            return try attributes(item)
        }
    }

    func lookupItem(named name: FSFileName, inDirectory directory: FSItem) async throws -> (FSItem, FSFileName) {
        try queue.sync { (try item(childPath(requireItem(directory), name)), name) }
    }
    func enumerateDirectory(_ directory: FSItem, startingAt cookie: FSDirectoryCookie,
                            verifier: FSDirectoryVerifier, attributes request: FSItem.GetAttributesRequest?,
                            packer: FSDirectoryEntryPacker) async throws -> FSDirectoryVerifier {
        try queue.sync {
            let directory = try requireItem(directory)
            if cookie.rawValue != 0 && verifier.rawValue != generation { throw FSError(.invalidDirectoryCookie) }
            let collector = EngineDirectory()
            try check(nk_list(engine, directory.path, { ctx, entry in
                guard let ctx, let entry, let name = entry.pointee.name else { return 1 }
                Unmanaged<EngineDirectory>.fromOpaque(ctx).takeUnretainedValue().entries.append((String(cString: name), entry.pointee.is_dir != 0))
                return 0
            }, Unmanaged.passUnretained(collector).toOpaque()))
            var entries = collector.entries
            if request == nil { entries.insert(contentsOf: [(".", true), ("..", true)], at: 0) }
            guard let first = Int(exactly: cookie.rawValue), first <= entries.count else { throw FSError(.invalidDirectoryCookie) }
            for i in first..<entries.count {
                let (name, isDir) = entries[i]
                let path = name == "." ? directory.path : name == ".." ?
                    (directory.path == "/" ? "/" : (directory.path as NSString).deletingLastPathComponent) :
                    try childPath(directory, FSFileName(string: name))
                let child = try item(path)
                let attrs = request == nil ? nil : try attributes(child)
                if !packer.packEntry(name: FSFileName(string: name), itemType: isDir ? .directory : .file,
                                     itemID: child.id, nextCookie: FSDirectoryCookie(rawValue: UInt64(i + 1)), attributes: attrs) { break }
            }
            return FSDirectoryVerifier(rawValue: generation)
        }
    }
    func createItem(named name: FSFileName, type: FSItem.ItemType, inDirectory directory: FSItem,
                    attributes request: FSItem.SetAttributesRequest) async throws -> (FSItem, FSFileName) {
        try queue.sync {
            let directory = try requireItem(directory)
            let path = try childPath(directory, name)
            guard type == .file || type == .directory, let nameString = name.string else { throw error(ENOTSUP) }
            try check(type == .directory ? nk_mkdir(engine, directory.path, nameString) : nk_create(engine, directory.path, nameString))
            generation &+= 1
            let child = try item(path)
            do { try apply(request, to: child) }
            catch {
                // If rollback fails, report that failure instead of hiding a leftover file.
                if nk_delete(engine, path) != 0 { throw self.error(EIO) }
                items.removeValue(forKey: child.inode)
                throw error
            }
            return (child, name)
        }
    }
    func removeItem(_ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem) async throws {
        try queue.sync {
            let item = try requireItem(item)
            guard try childPath(requireItem(directory), name).caseInsensitiveCompare(item.path) == .orderedSame else { throw error(ESTALE) }
            try check(nk_delete(engine, item.path))
            items.removeValue(forKey: item.inode)
            generation &+= 1
        }
    }
    func renameItem(_ source: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName,
                    to destinationName: FSFileName, inDirectory destinationDirectory: FSItem,
                    overItem: FSItem?) async throws -> FSFileName {
        try queue.sync {
            let source = try requireItem(source), destination = try requireItem(destinationDirectory)
            guard try childPath(requireItem(sourceDirectory), sourceName).caseInsensitiveCompare(source.path) == .orderedSame,
                  let newName = destinationName.string else { throw error(ESTALE) }
            let oldPath = source.path, newPath = try childPath(destination, destinationName)
            var recovery = [CChar](repeating: 0, count: 4096)
            let result = nk_move(engine, oldPath, destination.path, newName, overItem == nil ? 0 : 1, &recovery, recovery.count)
            if result != 0 {
                generation &+= 1
                let recoveryPath = String(cString: recovery)
                if !recoveryPath.isEmpty {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO), userInfo: [NSLocalizedDescriptionKey:
                        "Rename incomplete. Preserved data: \(recoveryPath). Stop using the volume and recover this file."])
                }
                throw error()
            }
            if let replaced = overItem as? EngineItem, replaced !== source { items.removeValue(forKey: replaced.inode) }
            for item in items.values {
                if item === source { item.path = newPath }
                else if item.path.lowercased().hasPrefix(oldPath.lowercased() + "/") {
                    item.path = newPath + item.path.dropFirst(oldPath.count)
                }
            }
            generation &+= 1
            return destinationName
        }
    }
    func reclaimItem(_ item: FSItem) async throws {
        queue.sync {
            if let item = item as? EngineItem, items[item.inode] === item { items.removeValue(forKey: item.inode) }
        }
    }
    func read(from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer) async throws -> Int {
        try queue.sync {
            let item = try requireItem(item)
            guard offset >= 0, length >= 0 else { throw error(EINVAL) }
            let count = buffer.withUnsafeMutableBytes { nk_read(engine, item.path, Int64(offset), Int64(min(length, $0.count)), $0.baseAddress) }
            guard count >= 0 else { throw error() }
            return Int(count)
        }
    }
    func write(contents: Data, to item: FSItem, at offset: off_t) async throws -> Int {
        try queue.sync {
            let item = try requireItem(item)
            guard offset >= 0 else { throw error(EINVAL) }
            let count = contents.withUnsafeBytes { nk_write(engine, item.path, Int64(offset), Int64($0.count), $0.baseAddress) }
            guard count >= 0 else { throw error() }
            return Int(count)
        }
    }
    func readSymbolicLink(_ item: FSItem) async throws -> FSFileName { throw error(ENOTSUP) }
    func createSymbolicLink(named name: FSFileName, inDirectory directory: FSItem,
                           attributes: FSItem.SetAttributesRequest, linkContents: FSFileName) async throws -> (FSItem, FSFileName) { throw error(ENOTSUP) }
    func createLink(to item: FSItem, named name: FSFileName, inDirectory directory: FSItem) async throws -> FSFileName { throw error(ENOTSUP) }
}
