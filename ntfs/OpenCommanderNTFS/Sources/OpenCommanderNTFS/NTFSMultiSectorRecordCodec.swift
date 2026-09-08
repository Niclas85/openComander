// SPDX-License-Identifier: MIT

import Foundation

/// Encodes a parsed FILE/INDX record for disk by rebuilding NTFS's update-sequence array.
public enum NTFSMultiSectorRecordCodec {
    public static func protect(_ fixedData: Data, bytesPerSector: Int) throws -> Data {
        guard bytesPerSector >= 512,
              fixedData.count >= bytesPerSector,
              fixedData.count % bytesPerSector == 0 else {
            throw NTFSError.invalidFileRecord("record does not contain whole sectors")
        }
        let reader = ByteReader(fixedData)
        let updateOffset = Int(try reader.uint16(at: 4))
        let updateCount = Int(try reader.uint16(at: 6))
        let sectorCount = fixedData.count / bytesPerSector
        guard updateCount == sectorCount + 1,
              updateOffset >= 8,
              updateOffset <= fixedData.count - updateCount * 2 else {
            throw NTFSError.invalidFileRecord("invalid update sequence array")
        }

        let sequence = try reader.bytes(at: updateOffset, count: 2)
        guard sequence != Data([0, 0]), sequence != Data([0xFF, 0xFF]) else {
            throw NTFSError.invalidFileRecord("reserved update sequence number")
        }
        var protected = fixedData
        for sectorIndex in 0..<sectorCount {
            let trailer = (sectorIndex + 1) * bytesPerSector - 2
            let currentTrailer = protected.subdata(in: trailer..<(trailer + 2))
            let replacementOffset = updateOffset + (sectorIndex + 1) * 2
            protected.replaceSubrange(replacementOffset..<(replacementOffset + 2), with: currentTrailer)
            protected.replaceSubrange(trailer..<(trailer + 2), with: sequence)
        }
        return protected
    }
}
