// SPDX-License-Identifier: MIT

import Foundation

public struct NTFSDataRun: Equatable {
    public let startVCN: UInt64
    public let length: UInt64
    public let startLCN: Int64?

    public var isSparse: Bool { startLCN == nil }
}

public enum NTFSRunlist {
    public static func decode(_ data: Data, startingVCN: UInt64 = 0) throws -> [NTFSDataRun] {
        let reader = ByteReader(data)
        var cursor = 0
        var vcn = startingVCN
        var previousLCN: Int64 = 0
        var result: [NTFSDataRun] = []

        while cursor < data.count {
            let header = try reader.uint8(at: cursor)
            cursor += 1
            if header == 0 { return result }
            let lengthBytes = Int(header & 0x0F)
            let offsetBytes = Int(header >> 4)
            guard (1...8).contains(lengthBytes), (0...8).contains(offsetBytes) else {
                throw NTFSError.invalidRunlist("invalid field width")
            }
            guard cursor <= data.count - lengthBytes - offsetBytes else {
                throw NTFSError.invalidRunlist("truncated run")
            }
            let length = try reader.unsignedInteger(at: cursor, byteCount: lengthBytes)
            cursor += lengthBytes
            guard length > 0 else { throw NTFSError.invalidRunlist("zero-length run") }

            let lcn: Int64?
            if offsetBytes == 0 {
                lcn = nil
            } else {
                let delta = try reader.signedInteger(at: cursor, byteCount: offsetBytes)
                let (nextLCN, overflow) = previousLCN.addingReportingOverflow(delta)
                guard !overflow, nextLCN >= 0 else { throw NTFSError.invalidRunlist("LCN overflow or negative LCN") }
                previousLCN = nextLCN
                lcn = nextLCN
            }
            cursor += offsetBytes
            result.append(NTFSDataRun(startVCN: vcn, length: length, startLCN: lcn))
            let (nextVCN, overflow) = vcn.addingReportingOverflow(length)
            guard !overflow else { throw NTFSError.invalidRunlist("VCN overflow") }
            vcn = nextVCN
        }
        throw NTFSError.invalidRunlist("missing terminator")
    }
}
