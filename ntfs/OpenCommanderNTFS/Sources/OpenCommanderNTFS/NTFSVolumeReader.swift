// SPDX-License-Identifier: MIT

import Foundation

public struct NTFSVolumeInformation: Equatable {
    public let majorVersion: UInt8
    public let minorVersion: UInt8
    public let flags: UInt16

    public var isDirty: Bool { flags & 0x0001 != 0 }
}

/// A bounded, read-only NTFS volume view used by the FSKit implementation and image tests.
/// It intentionally exposes no namespace mutation until the metadata writer is complete.
public final class NTFSVolumeReader {
    public static let dataAttributeType: UInt32 = 0x80
    public static let volumeInformationAttributeType: UInt32 = 0x70

    public let device: NTFSBlockDevice
    public let bootSector: NTFSBootSector
    private var cachedMFTRecord: NTFSFileRecord?

    public init(device: NTFSBlockDevice) throws {
        self.device = device
        let readSize = max(512, device.sectorSize)
        let boot = try NTFSBootSector(data: device.read(offset: 0, length: readSize))
        guard boot.volumeSize <= device.size else {
            throw NTFSError.invalidBootSector("declared volume is larger than the block device")
        }
        self.bootSector = boot
    }

    public func readMFTRecord(_ number: UInt64) throws -> NTFSFileRecord {
        if number == 0, let cachedMFTRecord { return cachedMFTRecord }
        let recordLength = Int(bootSector.fileRecordSize)
        let data: Data
        if number == 0 {
            let byteOffset = try multiplied(bootSector.mftCluster, UInt64(bootSector.clusterSize))
            data = try device.read(offset: byteOffset, length: recordLength)
        } else {
            let mft = try readMFTRecord(0)
            guard let stream = mft.attributes.first(where: { $0.type == Self.dataAttributeType && $0.name == nil }) else {
                throw NTFSError.invalidFileRecord("$MFT has no unnamed data stream")
            }
            let byteOffset = try multiplied(number, UInt64(recordLength))
            data = try read(attribute: stream, offset: byteOffset, length: recordLength)
        }
        let record = try NTFSFileRecord(data: data, bytesPerSector: Int(bootSector.bytesPerSector))
        if number == 0 { cachedMFTRecord = record }
        return record
    }

    public func volumeInformation() throws -> NTFSVolumeInformation {
        let volumeRecord = try readMFTRecord(3)
        guard let information = volumeRecord.attributes.first(where: { $0.type == Self.volumeInformationAttributeType }),
              let value = information.value,
              value.count >= 12 else {
            throw NTFSError.invalidAttribute("$Volume has no valid volume-information attribute")
        }
        let reader = ByteReader(value)
        return NTFSVolumeInformation(
            majorVersion: try reader.uint8(at: 8),
            minorVersion: try reader.uint8(at: 9),
            flags: try reader.uint16(at: 10)
        )
    }

    public func volumeFlags() throws -> UInt16 {
        try volumeInformation().flags
    }

    public func bootSectorBackupMatches() throws -> Bool {
        let sectorLength = Int(bootSector.bytesPerSector)
        let offset = bootSector.volumeSize - UInt64(sectorLength)
        let backup = try NTFSBootSector(data: device.read(offset: offset, length: sectorLength))
        return backup == bootSector
    }

    public func mftMirrorRecordZeroMatches() throws -> Bool {
        let offset = try multiplied(bootSector.mftMirrorCluster, UInt64(bootSector.clusterSize))
        let mirrorData = try device.read(offset: offset, length: Int(bootSector.fileRecordSize))
        let mirror = try NTFSFileRecord(
            data: mirrorData,
            bytesPerSector: Int(bootSector.bytesPerSector)
        )
        return mirror.fixedData == (try readMFTRecord(0)).fixedData
    }

    public func read(attribute: NTFSAttribute, offset: UInt64, length: Int) throws -> Data {
        guard length >= 0 else { throw NTFSError.outOfBounds(offset: offset, length: length) }
        if let resident = attribute.value {
            guard offset <= UInt64(resident.count), UInt64(length) <= UInt64(resident.count) - offset else {
                throw NTFSError.outOfBounds(offset: offset, length: length)
            }
            let start = Int(offset)
            return resident.subdata(in: start..<(start + length))
        }
        guard let dataSize = attribute.dataSize,
              offset <= dataSize, UInt64(length) <= dataSize - offset else {
            throw NTFSError.outOfBounds(offset: offset, length: length)
        }

        let clusterSize = UInt64(bootSector.clusterSize)
        var logicalOffset = offset
        var remaining = length
        var output = Data()
        output.reserveCapacity(length)
        while remaining > 0 {
            let vcn = logicalOffset / clusterSize
            guard let run = attribute.dataRuns.first(where: { vcn >= $0.startVCN && vcn < $0.startVCN + $0.length }) else {
                throw NTFSError.invalidRunlist("data offset is not covered by a run")
            }
            let offsetInRun = logicalOffset - run.startVCN * clusterSize
            let runBytes = run.length * clusterSize
            let chunkLength = Int(min(UInt64(remaining), runBytes - offsetInRun))
            if let startLCN = run.startLCN {
                let physicalBase = try multiplied(UInt64(startLCN), clusterSize)
                let (physicalOffset, overflow) = physicalBase.addingReportingOverflow(offsetInRun)
                guard !overflow else {
                    throw NTFSError.outOfBounds(offset: physicalBase, length: chunkLength)
                }
                output.append(try device.read(offset: physicalOffset, length: chunkLength))
            } else {
                output.append(Data(repeating: 0, count: chunkLength))
            }
            logicalOffset += UInt64(chunkLength)
            remaining -= chunkLength
        }
        return output
    }

    private func multiplied(_ left: UInt64, _ right: UInt64) throws -> UInt64 {
        let (result, overflow) = left.multipliedReportingOverflow(by: right)
        guard !overflow else { throw NTFSError.outOfBounds(offset: left, length: Int(clamping: right)) }
        return result
    }
}
