// SPDX-License-Identifier: MIT

import Foundation

public struct NTFSFileName: Equatable {
    public let parentFileReference: UInt64
    public let allocatedSize: UInt64
    public let dataSize: UInt64
    public let fileAttributes: UInt32
    public let namespace: UInt8
    public let name: String

    public var isDirectory: Bool { fileAttributes & 0x1000_0000 != 0 }

    public init(data: Data) throws {
        guard data.count >= 66 else {
            throw NTFSError.invalidAttribute("FILE_NAME value is too short")
        }
        let reader = ByteReader(data)
        let nameLength = Int(try reader.uint8(at: 64))
        let namespace = try reader.uint8(at: 65)
        guard namespace <= 3, nameLength <= (data.count - 66) / 2 else {
            throw NTFSError.invalidAttribute("FILE_NAME name is outside the value")
        }
        let nameData = try reader.bytes(at: 66, count: nameLength * 2)
        guard let name = String(data: nameData, encoding: .utf16LittleEndian) else {
            throw NTFSError.invalidAttribute("FILE_NAME contains invalid UTF-16")
        }
        self.parentFileReference = try reader.uint64(at: 0)
        self.allocatedSize = try reader.uint64(at: 40)
        self.dataSize = try reader.uint64(at: 48)
        self.fileAttributes = try reader.uint32(at: 56)
        self.namespace = namespace
        self.name = name
    }
}

public struct NTFSDirectoryEntry: Equatable {
    public let fileReference: UInt64
    public let fileName: NTFSFileName
    public let childVCN: UInt64?

    public var recordNumber: UInt64 { fileReference & 0x0000_FFFF_FFFF_FFFF }
    public var sequenceNumber: UInt16 { UInt16(fileReference >> 48) }
}

public struct NTFSDirectoryIndexRoot: Equatable {
    public let entries: [NTFSDirectoryEntry]
    public let hasIndexAllocation: Bool
}

public enum NTFSDirectoryIndex {
    public static func parseRoot(_ data: Data) throws -> NTFSDirectoryIndexRoot {
        guard data.count >= 32 else {
            throw NTFSError.invalidAttribute("INDEX_ROOT value is too short")
        }
        let reader = ByteReader(data)
        guard try reader.uint32(at: 0) == 0x30 else {
            throw NTFSError.invalidAttribute("directory index is not keyed by FILE_NAME")
        }
        let headerOffset = 16
        let entries = try parseEntries(reader: reader, headerOffset: headerOffset, limit: data.count)
        return NTFSDirectoryIndexRoot(
            entries: entries,
            hasIndexAllocation: try reader.uint8(at: headerOffset + 12) & 0x01 != 0
        )
    }

    public static func parseBuffer(_ data: Data, bytesPerSector: Int) throws -> [NTFSDirectoryEntry] {
        let fixed = try applyUpdateSequence(data, bytesPerSector: bytesPerSector)
        let reader = ByteReader(fixed)
        guard try reader.bytes(at: 0, count: 4) == Data("INDX".utf8), fixed.count >= 40 else {
            throw NTFSError.invalidAttribute("index buffer has no INDX signature")
        }
        return try parseEntries(reader: reader, headerOffset: 24, limit: fixed.count)
    }

    private static func parseEntries(reader: ByteReader, headerOffset: Int, limit: Int) throws -> [NTFSDirectoryEntry] {
        let entriesOffset = Int(try reader.uint32(at: headerOffset))
        let entriesSize = Int(try reader.uint32(at: headerOffset + 4))
        guard entriesOffset >= 16,
              entriesSize >= entriesOffset,
              headerOffset <= limit - entriesSize else {
            throw NTFSError.invalidAttribute("index entry bounds are invalid")
        }
        var cursor = headerOffset + entriesOffset
        let end = headerOffset + entriesSize
        var result: [NTFSDirectoryEntry] = []
        while cursor <= end - 16 {
            let entryLength = Int(try reader.uint16(at: cursor + 8))
            let keyLength = Int(try reader.uint16(at: cursor + 10))
            let flags = try reader.uint16(at: cursor + 12)
            let hasChild = flags & 0x0001 != 0
            let isLast = flags & 0x0002 != 0
            guard entryLength >= 16, entryLength <= end - cursor else {
                throw NTFSError.invalidAttribute("index entry length is invalid")
            }
            let childBytes = hasChild ? 8 : 0
            guard keyLength <= entryLength - 16 - childBytes else {
                throw NTFSError.invalidAttribute("index key is outside its entry")
            }
            if keyLength > 0 {
                let fileName = try NTFSFileName(data: reader.bytes(at: cursor + 16, count: keyLength))
                let childVCN = hasChild
                    ? try reader.uint64(at: cursor + entryLength - 8)
                    : nil
                result.append(NTFSDirectoryEntry(
                    fileReference: try reader.uint64(at: cursor),
                    fileName: fileName,
                    childVCN: childVCN
                ))
            }
            if isLast { return result }
            cursor += entryLength
        }
        throw NTFSError.invalidAttribute("directory index has no final entry")
    }

    private static func applyUpdateSequence(_ data: Data, bytesPerSector: Int) throws -> Data {
        guard bytesPerSector >= 512,
              data.count >= bytesPerSector,
              data.count % bytesPerSector == 0 else {
            throw NTFSError.invalidAttribute("index buffer does not contain whole sectors")
        }
        let raw = ByteReader(data)
        let updateOffset = Int(try raw.uint16(at: 4))
        let updateCount = Int(try raw.uint16(at: 6))
        let sectorCount = data.count / bytesPerSector
        guard updateCount == sectorCount + 1,
              updateOffset >= 8,
              updateOffset <= data.count - updateCount * 2 else {
            throw NTFSError.invalidAttribute("index update sequence is invalid")
        }
        let sequence = try raw.bytes(at: updateOffset, count: 2)
        var fixed = data
        for sectorIndex in 0..<sectorCount {
            let trailer = (sectorIndex + 1) * bytesPerSector - 2
            guard fixed.subdata(in: trailer..<(trailer + 2)) == sequence else {
                throw NTFSError.invalidAttribute("torn index buffer sector")
            }
            let replacement = try raw.bytes(at: updateOffset + (sectorIndex + 1) * 2, count: 2)
            fixed.replaceSubrange(trailer..<(trailer + 2), with: replacement)
        }
        return fixed
    }
}
