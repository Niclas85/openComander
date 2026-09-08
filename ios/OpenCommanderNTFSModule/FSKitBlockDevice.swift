// SPDX-License-Identifier: MIT

import Foundation
import FSKit
import OpenCommanderNTFS

/// The only bridge between FSKit's privileged block resource and the portable NTFS core.
/// FSKit owns and authorizes the underlying device; this type never opens `/dev/disk*`.
final class FSKitBlockDevice: NTFSBlockDevice {
    private let aligned: SectorAlignedBlockDevice

    var size: UInt64 { aligned.size }
    var sectorSize: Int { aligned.sectorSize }
    var isWritable: Bool { aligned.isWritable }

    init(resource: FSBlockDeviceResource) throws {
        aligned = try SectorAlignedBlockDevice(device: FSKitRawBlockDevice(resource: resource))
    }

    func read(offset: UInt64, length: Int) throws -> Data {
        try aligned.read(offset: offset, length: length)
    }

    func write(offset: UInt64, data: Data) throws {
        try aligned.write(offset: offset, data: data)
    }

    func synchronize() throws { try aligned.synchronize() }
}

private final class FSKitRawBlockDevice: NTFSBlockDevice {
    let resource: FSBlockDeviceResource

    let size: UInt64
    let sectorSize: Int
    var isWritable: Bool { resource.isWritable }

    init(resource: FSBlockDeviceResource) throws {
        let capacity = resource.blockSize.multipliedReportingOverflow(by: resource.blockCount)
        guard !capacity.overflow, capacity.partialValue <= UInt64(Int64.max),
              resource.blockSize > 0,
              resource.physicalBlockSize >= resource.blockSize,
              resource.physicalBlockSize % resource.blockSize == 0,
              let sector = Int(exactly: resource.physicalBlockSize) else {
            throw NTFSError.invalidDeviceGeometry("FSKit resource geometry cannot be represented safely")
        }
        self.size = capacity.partialValue
        self.sectorSize = sector
        self.resource = resource
    }

    func read(offset: UInt64, length: Int) throws -> Data {
        guard offset <= size, length >= 0, UInt64(length) <= size - offset else {
            throw NTFSError.outOfBounds(offset: offset, length: length)
        }
        var data = Data(repeating: 0, count: length)
        let actual = try data.withUnsafeMutableBytes { buffer in
            try resource.read(into: buffer, startingAt: off_t(offset), length: length)
        }
        guard actual == length else { throw NTFSError.shortRead(expected: length, actual: actual) }
        return data
    }

    func write(offset: UInt64, data: Data) throws {
        guard isWritable else { throw NTFSError.readOnly("FSKit resource is read-only") }
        guard offset <= size, UInt64(data.count) <= size - offset else {
            throw NTFSError.outOfBounds(offset: offset, length: data.count)
        }
        let actual = try data.withUnsafeBytes { buffer in
            try resource.write(from: buffer, startingAt: off_t(offset), length: data.count)
        }
        guard actual == data.count else { throw NTFSError.shortWrite(expected: data.count, actual: actual) }
    }

    func synchronize() throws {
        try resource.metadataFlush()
    }
}
