// SPDX-License-Identifier: MIT

import Foundation

public protocol NTFSBlockDevice: AnyObject {
    var size: UInt64 { get }
    var sectorSize: Int { get }
    var isWritable: Bool { get }
    func read(offset: UInt64, length: Int) throws -> Data
    func write(offset: UInt64, data: Data) throws
    func synchronize() throws
}

public final class MemoryBlockDevice: NTFSBlockDevice {
    private var storage: Data
    public let sectorSize: Int
    public let isWritable: Bool

    public var size: UInt64 { UInt64(storage.count) }

    public init(data: Data, sectorSize: Int = 512, writable: Bool = false) {
        self.storage = data
        self.sectorSize = sectorSize
        self.isWritable = writable
    }

    public func read(offset: UInt64, length: Int) throws -> Data {
        guard offset <= UInt64(storage.count), length >= 0, UInt64(length) <= UInt64(storage.count) - offset else {
            throw NTFSError.outOfBounds(offset: offset, length: length)
        }
        let start = Int(offset)
        return storage.subdata(in: start..<(start + length))
    }

    public func write(offset: UInt64, data: Data) throws {
        guard isWritable else { throw NTFSError.readOnly("block device is read-only") }
        guard offset <= UInt64(storage.count), UInt64(data.count) <= UInt64(storage.count) - offset else {
            throw NTFSError.outOfBounds(offset: offset, length: data.count)
        }
        let start = Int(offset)
        storage.replaceSubrange(start..<(start + data.count), with: data)
    }

    public func synchronize() throws {}
}

public final class FileBlockDevice: NTFSBlockDevice {
    private let handle: FileHandle
    public let size: UInt64
    public let sectorSize: Int
    public let isWritable: Bool

    public init(url: URL, sectorSize: Int = 512, writable: Bool = false) throws {
        self.sectorSize = sectorSize
        self.isWritable = writable
        self.handle = writable ? try FileHandle(forUpdating: url) : try FileHandle(forReadingFrom: url)
        self.size = try handle.seekToEnd()
    }

    deinit { try? handle.close() }

    public func read(offset: UInt64, length: Int) throws -> Data {
        guard offset <= size, length >= 0, UInt64(length) <= size - offset else {
            throw NTFSError.outOfBounds(offset: offset, length: length)
        }
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: length) ?? Data()
        guard data.count == length else { throw NTFSError.shortRead(expected: length, actual: data.count) }
        return data
    }

    public func write(offset: UInt64, data: Data) throws {
        guard isWritable else { throw NTFSError.readOnly("image was opened read-only") }
        guard offset <= size, UInt64(data.count) <= size - offset else {
            throw NTFSError.outOfBounds(offset: offset, length: data.count)
        }
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: data)
    }

    public func synchronize() throws { try handle.synchronize() }
}
