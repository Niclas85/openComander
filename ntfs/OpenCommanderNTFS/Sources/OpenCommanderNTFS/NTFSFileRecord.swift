// SPDX-License-Identifier: MIT

import Foundation

public struct NTFSAttribute: Equatable {
    public let type: UInt32
    public let identifier: UInt16
    public let name: String?
    public let flags: UInt16
    public let value: Data?
    public let dataRuns: [NTFSDataRun]
    public let allocatedSize: UInt64?
    public let dataSize: UInt64?
    public let initializedSize: UInt64?

    public var isNonResident: Bool { value == nil }
}

public struct NTFSFileRecord: Equatable {
    public let sequenceNumber: UInt16
    public let hardLinkCount: UInt16
    public let flags: UInt16
    public let recordNumber: UInt32
    public let baseFileReference: UInt64
    public let attributes: [NTFSAttribute]
    public let fixedData: Data

    public var isInUse: Bool { flags & 0x0001 != 0 }
    public var isDirectory: Bool { flags & 0x0002 != 0 }

    public init(data: Data, bytesPerSector: Int) throws {
        guard bytesPerSector >= 512, data.count >= bytesPerSector, data.count % bytesPerSector == 0 else {
            throw NTFSError.invalidFileRecord("record does not contain whole sectors")
        }
        let raw = ByteReader(data)
        guard try raw.bytes(at: 0, count: 4) == Data("FILE".utf8) else {
            throw NTFSError.invalidFileRecord("missing FILE signature")
        }
        let updateOffset = Int(try raw.uint16(at: 4))
        let updateCount = Int(try raw.uint16(at: 6))
        let sectorCount = data.count / bytesPerSector
        guard updateCount == sectorCount + 1 else {
            throw NTFSError.invalidFileRecord("update sequence count mismatch")
        }
        guard updateOffset >= 8, updateOffset <= data.count - updateCount * 2 else {
            throw NTFSError.invalidFileRecord("update sequence array outside record")
        }
        let sequence = try raw.bytes(at: updateOffset, count: 2)
        var fixed = data
        for sector in 0..<sectorCount {
            let trailer = (sector + 1) * bytesPerSector - 2
            guard fixed.subdata(in: trailer..<(trailer + 2)) == sequence else {
                throw NTFSError.invalidFileRecord("torn or corrupt sector \(sector)")
            }
            let replacement = try raw.bytes(at: updateOffset + (sector + 1) * 2, count: 2)
            fixed.replaceSubrange(trailer..<(trailer + 2), with: replacement)
        }

        let reader = ByteReader(fixed)
        let firstAttribute = Int(try reader.uint16(at: 20))
        let bytesInUse = Int(try reader.uint32(at: 24))
        guard firstAttribute >= 24, bytesInUse <= fixed.count, firstAttribute < bytesInUse else {
            throw NTFSError.invalidFileRecord("invalid attribute bounds")
        }
        var attributes: [NTFSAttribute] = []
        var cursor = firstAttribute
        while cursor <= bytesInUse - 4 {
            let type = try reader.uint32(at: cursor)
            if type == 0xFFFF_FFFF { break }
            let length = Int(try reader.uint32(at: cursor + 4))
            guard length >= 24, cursor <= bytesInUse - length else {
                throw NTFSError.invalidAttribute("invalid attribute length")
            }
            attributes.append(try Self.parseAttribute(reader: reader, offset: cursor, length: length, type: type))
            cursor += length
        }
        self.sequenceNumber = try reader.uint16(at: 16)
        self.hardLinkCount = try reader.uint16(at: 18)
        self.flags = try reader.uint16(at: 22)
        self.baseFileReference = try reader.uint64(at: 32)
        self.recordNumber = fixed.count >= 48 ? try reader.uint32(at: 44) : 0
        self.attributes = attributes
        self.fixedData = fixed
    }

    private static func parseAttribute(reader: ByteReader, offset: Int, length: Int, type: UInt32) throws -> NTFSAttribute {
        let nonResident = try reader.uint8(at: offset + 8) != 0
        let nameLength = Int(try reader.uint8(at: offset + 9))
        let nameOffset = Int(try reader.uint16(at: offset + 10))
        let flags = try reader.uint16(at: offset + 12)
        let identifier = try reader.uint16(at: offset + 14)
        var name: String?
        if nameLength > 0 {
            let byteLength = nameLength * 2
            guard nameOffset >= 16, nameOffset <= length - byteLength else {
                throw NTFSError.invalidAttribute("name outside attribute")
            }
            let nameData = try reader.bytes(at: offset + nameOffset, count: byteLength)
            name = String(data: nameData, encoding: .utf16LittleEndian)
            guard name != nil else { throw NTFSError.invalidAttribute("invalid UTF-16 name") }
        }

        if !nonResident {
            let valueLength = Int(try reader.uint32(at: offset + 16))
            let valueOffset = Int(try reader.uint16(at: offset + 20))
            guard valueOffset >= 24, valueOffset <= length - valueLength else {
                throw NTFSError.invalidAttribute("resident value outside attribute")
            }
            return NTFSAttribute(
                type: type, identifier: identifier, name: name, flags: flags,
                value: try reader.bytes(at: offset + valueOffset, count: valueLength), dataRuns: [],
                allocatedSize: nil, dataSize: UInt64(valueLength), initializedSize: UInt64(valueLength)
            )
        }

        guard length >= 64 else { throw NTFSError.invalidAttribute("nonresident header is too short") }
        let lowestVCN = try reader.uint64(at: offset + 16)
        let runOffset = Int(try reader.uint16(at: offset + 32))
        guard runOffset >= 64, runOffset < length else {
            throw NTFSError.invalidAttribute("runlist outside attribute")
        }
        let runData = try reader.bytes(at: offset + runOffset, count: length - runOffset)
        return NTFSAttribute(
            type: type, identifier: identifier, name: name, flags: flags, value: nil,
            dataRuns: try NTFSRunlist.decode(runData, startingVCN: lowestVCN),
            allocatedSize: try reader.uint64(at: offset + 40),
            dataSize: try reader.uint64(at: offset + 48),
            initializedSize: try reader.uint64(at: offset + 56)
        )
    }
}
