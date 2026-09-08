// SPDX-License-Identifier: MIT

import Foundation

/// Adapts byte-range I/O to a device that requires whole physical sectors.
/// All access to the underlying device must go through this single adapter.
/// Serialization protects read-modify-write within this instance only; it is
/// not a filesystem transaction, crash recovery, or protection from other writers.
public final class SectorAlignedBlockDevice: NTFSBlockDevice {
    private let device: NTFSBlockDevice
    private let lock = NSLock()
    private let transferLimit: Int
    public let size: UInt64
    public let sectorSize: Int
    public var isWritable: Bool { device.isWritable }

    public init(device: NTFSBlockDevice, maximumTransferSize: Int = 1024 * 1024) throws {
        let sector = device.sectorSize
        guard sector >= 512, sector <= 1024 * 1024, sector.nonzeroBitCount == 1,
              device.size > 0, device.size % UInt64(sector) == 0,
              maximumTransferSize >= sector else {
            throw NTFSError.invalidDeviceGeometry("unsupported sector size, partial final sector, or transfer limit")
        }
        self.device = device
        self.size = device.size
        self.sectorSize = sector
        self.transferLimit = maximumTransferSize - maximumTransferSize % sector
    }

    public func read(offset: UInt64, length: Int) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        try validate(offset: offset, length: length)
        var result = Data()
        var cursor = offset
        var remaining = length
        while remaining > 0 {
            let (start, prefix, count, transfer) = window(offset: cursor, remaining: remaining)
            let bytes = try readExactly(offset: start, length: transfer)
            result.append(bytes.subdata(in: prefix..<(prefix + count)))
            cursor += UInt64(count)
            remaining -= count
        }
        return result
    }

    public func write(offset: UInt64, data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard isWritable else { throw NTFSError.readOnly("block device is read-only") }
        try validate(offset: offset, length: data.count)
        var cursor = offset
        var consumed = 0
        while consumed < data.count {
            let (start, prefix, count, transfer) = window(offset: cursor, remaining: data.count - consumed)
            let begin = data.index(data.startIndex, offsetBy: consumed)
            let end = data.index(begin, offsetBy: count)
            let replacement = Data(data[begin..<end])
            if prefix == 0 && count == transfer {
                try device.write(offset: start, data: replacement)
            } else {
                var bytes = try readExactly(offset: start, length: transfer)
                bytes.replaceSubrange(prefix..<(prefix + count), with: replacement)
                try device.write(offset: start, data: bytes)
            }
            cursor += UInt64(count)
            consumed += count
        }
    }

    public func synchronize() throws {
        lock.lock()
        defer { lock.unlock() }
        try device.synchronize()
    }

    private func validate(offset: UInt64, length: Int) throws {
        guard offset <= size, length >= 0, UInt64(length) <= size - offset else {
            throw NTFSError.outOfBounds(offset: offset, length: length)
        }
    }

    private func readExactly(offset: UInt64, length: Int) throws -> Data {
        let data = try device.read(offset: offset, length: length)
        guard data.count == length else { throw NTFSError.shortRead(expected: length, actual: data.count) }
        return Data(data)
    }

    private func window(offset: UInt64, remaining: Int) -> (UInt64, Int, Int, Int) {
        let prefix = Int(offset % UInt64(sectorSize))
        let count = min(remaining, transferLimit - prefix)
        let covered = prefix + count
        let transfer = ((covered - 1) / sectorSize + 1) * sectorSize
        return (offset - UInt64(prefix), prefix, count, transfer)
    }
}
