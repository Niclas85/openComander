// SPDX-License-Identifier: MIT

import Foundation

public struct NTFSBootSector: Equatable {
    public static let oemIdentifier = Data("NTFS    ".utf8)

    public let bytesPerSector: UInt16
    public let sectorsPerCluster: UInt8
    public let totalSectors: UInt64
    public let mftCluster: UInt64
    public let mftMirrorCluster: UInt64
    public let fileRecordSize: UInt32
    public let indexBufferSize: UInt32
    public let volumeSerialNumber: UInt64

    public var clusterSize: UInt32 {
        UInt32(bytesPerSector) * UInt32(sectorsPerCluster)
    }

    public var volumeSize: UInt64 {
        totalSectors * UInt64(bytesPerSector)
    }

    public init(data: Data) throws {
        guard data.count >= 512 else { throw NTFSError.invalidBootSector("fewer than 512 bytes") }
        let reader = ByteReader(data)
        guard try reader.bytes(at: 3, count: 8) == Self.oemIdentifier else {
            throw NTFSError.invalidBootSector("OEM identifier is not NTFS")
        }
        let bytesPerSector = try reader.uint16(at: 11)
        guard [512, 1024, 2048, 4096].contains(bytesPerSector) else {
            throw NTFSError.invalidBootSector("unsupported sector size \(bytesPerSector)")
        }
        let sectorsPerCluster = try reader.uint8(at: 13)
        guard sectorsPerCluster != 0, sectorsPerCluster.nonzeroBitCount == 1 else {
            throw NTFSError.invalidBootSector("sectors per cluster must be a power of two")
        }
        let clusterSize64 = UInt64(bytesPerSector) * UInt64(sectorsPerCluster)
        guard clusterSize64 <= 2 * 1024 * 1024 else {
            throw NTFSError.invalidBootSector("cluster size is implausibly large")
        }
        let totalSectors = try reader.uint64(at: 40)
        let mftCluster = try reader.uint64(at: 48)
        let mftMirrorCluster = try reader.uint64(at: 56)
        guard totalSectors > 0 else { throw NTFSError.invalidBootSector("empty volume") }
        let totalClusters = totalSectors / UInt64(sectorsPerCluster)
        guard mftCluster < totalClusters, mftMirrorCluster < totalClusters else {
            throw NTFSError.invalidBootSector("MFT location is outside the volume")
        }
        let fileRecordSize = try Self.recordSize(encoded: reader.int8(at: 64), clusterSize: clusterSize64)
        let indexBufferSize = try Self.recordSize(encoded: reader.int8(at: 68), clusterSize: clusterSize64)
        guard try reader.uint16(at: 510) == 0xAA55 else {
            throw NTFSError.invalidBootSector("missing 0x55AA signature")
        }
        self.bytesPerSector = bytesPerSector
        self.sectorsPerCluster = sectorsPerCluster
        self.totalSectors = totalSectors
        self.mftCluster = mftCluster
        self.mftMirrorCluster = mftMirrorCluster
        self.fileRecordSize = fileRecordSize
        self.indexBufferSize = indexBufferSize
        self.volumeSerialNumber = try reader.uint64(at: 72)
    }

    private static func recordSize(encoded: Int8, clusterSize: UInt64) throws -> UInt32 {
        guard encoded != 0 else { throw NTFSError.invalidBootSector("zero record size") }
        let size: UInt64
        if encoded > 0 {
            size = UInt64(encoded) * clusterSize
        } else {
            let exponent = Int(-Int16(encoded))
            guard exponent < 32 else { throw NTFSError.invalidBootSector("record size exponent is too large") }
            size = UInt64(1) << UInt64(exponent)
        }
        guard size >= 512, size <= UInt64(UInt32.max), size.nonzeroBitCount == 1 else {
            throw NTFSError.invalidBootSector("invalid record size \(size)")
        }
        return UInt32(size)
    }
}
