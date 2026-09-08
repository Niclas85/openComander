// SPDX-License-Identifier: MIT

import Foundation

public enum NTFSHibernationState: Equatable {
    case notPresent
    case inactive
    case active
    case unknown
}

public extension NTFSVolumeReader {
    static var indexRootAttributeType: UInt32 { 0x90 }
    static var indexAllocationAttributeType: UInt32 { 0xA0 }
    static var bitmapAttributeType: UInt32 { 0xB0 }

    func directoryEntries(recordNumber: UInt64) throws -> [NTFSDirectoryEntry] {
        let directory = try readMFTRecord(recordNumber)
        guard directory.isInUse, directory.isDirectory else {
            throw NTFSError.invalidFileRecord("record is not an active directory")
        }
        guard let rootAttribute = directory.attributes.first(where: {
            $0.type == Self.indexRootAttributeType && ($0.name == "$I30" || $0.name == nil)
        }), let rootValue = rootAttribute.value else {
            throw NTFSError.invalidAttribute("directory has no resident $I30 INDEX_ROOT")
        }
        let root = try NTFSDirectoryIndex.parseRoot(rootValue)
        guard root.hasIndexAllocation else { return root.entries }

        guard let allocation = directory.attributes.first(where: {
            $0.type == Self.indexAllocationAttributeType && ($0.name == "$I30" || $0.name == nil)
        }), let allocationSize = allocation.dataSize,
              let bitmap = directory.attributes.first(where: {
                  $0.type == Self.bitmapAttributeType && ($0.name == "$I30" || $0.name == nil)
              }), let bitmapSize = bitmap.dataSize else {
            throw NTFSError.invalidAttribute("large directory is missing $I30 allocation metadata")
        }

        let bufferSize = UInt64(bootSector.indexBufferSize)
        let bufferCount = allocationSize / bufferSize + (allocationSize % bufferSize == 0 ? 0 : 1)
        let neededBitmapBytes = bufferCount / 8 + (bufferCount % 8 == 0 ? 0 : 1)
        // Refuse implausible/corrupt directory metadata before allocating memory or looping.
        let maximumBitmapBytes: UInt64 = 16 * 1024 * 1024
        guard bufferCount <= device.size / bufferSize,
              neededBitmapBytes <= bitmapSize,
              neededBitmapBytes <= maximumBitmapBytes,
              neededBitmapBytes <= UInt64(Int.max) else {
            throw NTFSError.invalidAttribute("directory allocation metadata is invalid or too large")
        }
        let bitmapData = try read(attribute: bitmap, offset: 0, length: Int(neededBitmapBytes))
        var entries = root.entries
        for index in 0..<bufferCount {
            let byte = bitmapData[Int(index / 8)]
            guard byte & (UInt8(1) << UInt8(index % 8)) != 0 else { continue }
            let offset = index * bufferSize
            guard offset <= allocationSize, bufferSize <= allocationSize - offset else {
                throw NTFSError.invalidAttribute("allocated index buffer is truncated")
            }
            let data = try read(attribute: allocation, offset: offset, length: Int(bufferSize))
            entries.append(contentsOf: try NTFSDirectoryIndex.parseBuffer(
                data,
                bytesPerSector: Int(bootSector.bytesPerSector)
            ))
        }
        return entries
    }

    func hibernationState() throws -> NTFSHibernationState {
        guard let entry = try directoryEntries(recordNumber: 5).first(where: {
            $0.fileName.name.compare("hiberfil.sys", options: [.caseInsensitive]) == .orderedSame
        }) else {
            return .notPresent
        }
        let record = try readMFTRecord(entry.recordNumber)
        guard record.isInUse, record.sequenceNumber == entry.sequenceNumber,
              let stream = record.attributes.first(where: {
                  $0.type == Self.dataAttributeType && $0.name == nil
              }), let dataSize = stream.dataSize else {
            return .unknown
        }
        guard dataSize > 0 else { return .inactive }
        let prefixLength = Int(min(dataSize, 4096))
        let prefix = try read(attribute: stream, offset: 0, length: prefixLength)
        if prefix.allSatisfy({ $0 == 0 }) { return .inactive }
        let signature = String(decoding: prefix.prefix(4), as: UTF8.self).lowercased()
        if signature == "hibr" || signature == "wake" { return .active }
        return .unknown
    }
}
