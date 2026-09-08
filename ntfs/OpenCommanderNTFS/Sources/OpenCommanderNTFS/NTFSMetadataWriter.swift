// SPDX-License-Identifier: MIT

import Foundation

/// Narrow, image-tested metadata writer. It can only replace an existing unnamed,
/// resident $DATA value without changing its size. Namespace and allocation changes
/// intentionally remain unsupported.
public final class NTFSMetadataWriter {
    private let volume: NTFSVolumeReader
    private let safetyState: NTFSVolumeSafetyState

    public init(volume: NTFSVolumeReader, safetyState: NTFSVolumeSafetyState) {
        self.volume = volume
        self.safetyState = safetyState
    }

    public func replaceResidentData(
        recordNumber: UInt64,
        expectedSequenceNumber: UInt16,
        expectedValue: Data,
        replacement: Data
    ) throws {
        // Records 0...23 are reserved for NTFS metadata and must not be modified by this
        // deliberately small writer.
        guard recordNumber >= 24 else {
            throw NTFSError.readOnly("NTFS system records are protected")
        }
        guard expectedValue.count == replacement.count else {
            throw NTFSError.readOnly("resident data replacement must preserve its size")
        }

        let record = try volume.readMFTRecord(recordNumber)
        guard record.isInUse, !record.isDirectory else {
            throw NTFSError.readOnly("record is not an active regular file")
        }
        guard record.sequenceNumber == expectedSequenceNumber else {
            throw NTFSError.readOnly("file record sequence changed")
        }
        let candidates = record.attributes.filter {
            $0.type == NTFSVolumeReader.dataAttributeType && $0.name == nil && !$0.isNonResident
        }
        guard candidates.count == 1, let attribute = candidates.first,
              attribute.value == expectedValue else {
            throw NTFSError.readOnly("resident data no longer matches the expected value")
        }

        let fixed = try patchResidentValue(
            in: record.fixedData,
            type: attribute.type,
            identifier: attribute.identifier,
            replacement: replacement
        )
        let protected = try NTFSMultiSectorRecordCodec.protect(
            fixed,
            bytesPerSector: Int(volume.bootSector.bytesPerSector)
        )
        let extents = try physicalExtentsForMFTRecord(recordNumber)
        guard extents.reduce(0, { $0 + $1.length }) == protected.count,
              let firstExtent = extents.first else {
            throw NTFSError.invalidRunlist("MFT record mapping is incomplete")
        }

        let transaction = try NTFSWriteTransaction(device: volume.device, safetyState: safetyState)
        do {
            var sourceOffset = 0
            for extent in extents {
                let chunk = protected.subdata(in: sourceOffset..<(sourceOffset + extent.length))
                try transaction.writeBytes(offset: extent.deviceOffset, data: chunk)
                sourceOffset += extent.length
            }

            // Reparse from the device before commit. This catches incorrect run mapping,
            // torn records, stale update sequences, and write failures while rollback is live.
            let verification = try NTFSVolumeReader(device: volume.device).readMFTRecord(recordNumber)
            guard verification.sequenceNumber == expectedSequenceNumber,
                  verification.attributes.first(where: {
                      $0.type == attribute.type && $0.identifier == attribute.identifier
                  })?.value == replacement else {
                throw NTFSError.writeVerificationFailed(
                    offset: firstExtent.deviceOffset,
                    length: protected.count
                )
            }
            try transaction.commit()
        } catch {
            try? transaction.rollback()
            throw error
        }
    }

    private struct PhysicalExtent {
        let deviceOffset: UInt64
        let length: Int
    }

    private func physicalExtentsForMFTRecord(_ number: UInt64) throws -> [PhysicalExtent] {
        let recordLength = UInt64(volume.bootSector.fileRecordSize)
        let (logicalOffset, overflow) = number.multipliedReportingOverflow(by: recordLength)
        guard !overflow else {
            throw NTFSError.outOfBounds(offset: number, length: Int(volume.bootSector.fileRecordSize))
        }
        let mft = try volume.readMFTRecord(0)
        guard let stream = mft.attributes.first(where: {
            $0.type == NTFSVolumeReader.dataAttributeType && $0.name == nil && $0.isNonResident
        }) else {
            throw NTFSError.invalidFileRecord("$MFT has no nonresident unnamed data stream")
        }
        guard let dataSize = stream.dataSize,
              logicalOffset <= dataSize,
              recordLength <= dataSize - logicalOffset else {
            throw NTFSError.outOfBounds(offset: logicalOffset, length: Int(recordLength))
        }

        let clusterSize = UInt64(volume.bootSector.clusterSize)
        var cursor = logicalOffset
        var remaining = Int(recordLength)
        var result: [PhysicalExtent] = []
        while remaining > 0 {
            let vcn = cursor / clusterSize
            guard let run = stream.dataRuns.first(where: {
                vcn >= $0.startVCN && vcn < $0.startVCN + $0.length
            }), let startLCN = run.startLCN else {
                throw NTFSError.invalidRunlist("MFT record maps to a missing or sparse run")
            }
            let offsetInRun = cursor - run.startVCN * clusterSize
            let available = run.length * clusterSize - offsetInRun
            let chunkLength = Int(min(UInt64(remaining), available))
            let (deviceBase, offsetOverflow) = UInt64(startLCN).multipliedReportingOverflow(by: clusterSize)
            let (finalOffset, additionOverflow) = deviceBase.addingReportingOverflow(offsetInRun)
            guard !offsetOverflow, !additionOverflow,
                  finalOffset <= volume.device.size,
                  UInt64(chunkLength) <= volume.device.size - finalOffset else {
                throw NTFSError.outOfBounds(offset: finalOffset, length: chunkLength)
            }
            result.append(PhysicalExtent(deviceOffset: finalOffset, length: chunkLength))
            cursor += UInt64(chunkLength)
            remaining -= chunkLength
        }
        return result
    }

    private func patchResidentValue(
        in record: Data,
        type wantedType: UInt32,
        identifier wantedIdentifier: UInt16,
        replacement: Data
    ) throws -> Data {
        let reader = ByteReader(record)
        let firstAttribute = Int(try reader.uint16(at: 20))
        let bytesInUse = Int(try reader.uint32(at: 24))
        var cursor = firstAttribute
        while cursor <= bytesInUse - 4 {
            let type = try reader.uint32(at: cursor)
            if type == 0xFFFF_FFFF { break }
            let length = Int(try reader.uint32(at: cursor + 4))
            guard length >= 24, cursor <= bytesInUse - length else {
                throw NTFSError.invalidAttribute("invalid attribute length while patching")
            }
            let identifier = try reader.uint16(at: cursor + 14)
            if type == wantedType, identifier == wantedIdentifier {
                guard try reader.uint8(at: cursor + 8) == 0 else {
                    throw NTFSError.readOnly("nonresident data replacement is unsupported")
                }
                let valueLength = Int(try reader.uint32(at: cursor + 16))
                let valueOffset = Int(try reader.uint16(at: cursor + 20))
                guard valueLength == replacement.count,
                      valueOffset >= 24,
                      valueOffset <= length - valueLength else {
                    throw NTFSError.invalidAttribute("resident value bounds changed")
                }
                var patched = record
                let start = cursor + valueOffset
                patched.replaceSubrange(start..<(start + valueLength), with: replacement)
                return patched
            }
            cursor += length
        }
        throw NTFSError.invalidAttribute("resident data attribute was not found")
    }
}
