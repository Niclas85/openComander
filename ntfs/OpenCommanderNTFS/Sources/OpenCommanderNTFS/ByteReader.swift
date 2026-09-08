// SPDX-License-Identifier: MIT

import Foundation

public struct ByteReader {
    public let data: Data

    public init(_ data: Data) {
        self.data = data
    }

    public func bytes(at offset: Int, count: Int) throws -> Data {
        guard offset >= 0, count >= 0, offset <= data.count, count <= data.count - offset else {
            throw NTFSError.outOfBounds(offset: UInt64(max(0, offset)), length: count)
        }
        return data.subdata(in: offset..<(offset + count))
    }

    public func uint8(at offset: Int) throws -> UInt8 {
        guard offset >= 0, offset < data.count else {
            throw NTFSError.outOfBounds(offset: UInt64(max(0, offset)), length: 1)
        }
        return data[offset]
    }

    public func int8(at offset: Int) throws -> Int8 {
        Int8(bitPattern: try uint8(at: offset))
    }

    public func uint16(at offset: Int) throws -> UInt16 {
        UInt16(try unsignedInteger(at: offset, byteCount: 2))
    }

    public func uint32(at offset: Int) throws -> UInt32 {
        UInt32(try unsignedInteger(at: offset, byteCount: 4))
    }

    public func uint64(at offset: Int) throws -> UInt64 {
        try unsignedInteger(at: offset, byteCount: 8)
    }

    public func unsignedInteger(at offset: Int, byteCount: Int) throws -> UInt64 {
        guard (0...8).contains(byteCount) else {
            throw NTFSError.outOfBounds(offset: UInt64(max(0, offset)), length: byteCount)
        }
        let value = try bytes(at: offset, count: byteCount)
        return value.enumerated().reduce(UInt64(0)) { partial, element in
            partial | (UInt64(element.element) << UInt64(element.offset * 8))
        }
    }

    public func signedInteger(at offset: Int, byteCount: Int) throws -> Int64 {
        guard (1...8).contains(byteCount) else {
            throw NTFSError.outOfBounds(offset: UInt64(max(0, offset)), length: byteCount)
        }
        let unsigned = try unsignedInteger(at: offset, byteCount: byteCount)
        if byteCount == 8 { return Int64(bitPattern: unsigned) }
        let signBit = UInt64(1) << UInt64(byteCount * 8 - 1)
        guard unsigned & signBit != 0 else { return Int64(unsigned) }
        let extensionMask = UInt64.max << UInt64(byteCount * 8)
        return Int64(bitPattern: unsigned | extensionMask)
    }
}
