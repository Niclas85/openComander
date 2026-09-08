// SPDX-License-Identifier: MIT

import XCTest
@testable import OpenCommanderNTFS

final class NTFSCoreTests: XCTestCase {
    func testParsesBootSectorAndRecordSizes() throws {
        let boot = makeBootSector()
        let parsed = try NTFSBootSector(data: boot)
        XCTAssertEqual(parsed.bytesPerSector, 512)
        XCTAssertEqual(parsed.sectorsPerCluster, 8)
        XCTAssertEqual(parsed.clusterSize, 4096)
        XCTAssertEqual(parsed.fileRecordSize, 1024)
        XCTAssertEqual(parsed.indexBufferSize, 4096)
        XCTAssertEqual(parsed.mftCluster, 4)
        XCTAssertEqual(parsed.volumeSerialNumber, 0x0123_4567_89AB_CDEF)
    }

    func testRejectsNonNTFSBootSector() {
        var boot = makeBootSector()
        boot.replaceSubrange(3..<11, with: Data("EXFAT   ".utf8))
        XCTAssertThrowsError(try NTFSBootSector(data: boot))
    }

    func testDecodesPositiveNegativeAndSparseRuns() throws {
        let encoded = Data([0x11, 0x03, 0x05, 0x11, 0x02, 0xFE, 0x01, 0x04, 0x00])
        let runs = try NTFSRunlist.decode(encoded)
        XCTAssertEqual(runs, [
            NTFSDataRun(startVCN: 0, length: 3, startLCN: 5),
            NTFSDataRun(startVCN: 3, length: 2, startLCN: 3),
            NTFSDataRun(startVCN: 5, length: 4, startLCN: nil)
        ])
    }

    func testAppliesUpdateSequenceAndParsesResidentAttribute() throws {
        let record = makeFileRecord()
        let parsed = try NTFSFileRecord(data: record, bytesPerSector: 512)
        XCTAssertTrue(parsed.isInUse)
        XCTAssertFalse(parsed.isDirectory)
        XCTAssertEqual(parsed.recordNumber, 42)
        XCTAssertEqual(parsed.attributes.count, 1)
        XCTAssertEqual(parsed.attributes[0].type, 0x80)
        XCTAssertEqual(parsed.attributes[0].value, Data("hello".utf8))
        XCTAssertEqual(parsed.fixedData[510], 0x34)
        XCTAssertEqual(parsed.fixedData[511], 0x12)
        XCTAssertEqual(parsed.fixedData[1022], 0x78)
        XCTAssertEqual(parsed.fixedData[1023], 0x56)
    }

    func testRejectsTornFileRecord() {
        var record = makeFileRecord()
        record[510] = 0
        XCTAssertThrowsError(try NTFSFileRecord(data: record, bytesPerSector: 512))
    }

    func testWriteGateDefaultsToReadOnly() {
        let device = MemoryBlockDevice(data: Data(repeating: 0, count: 1024), writable: true)
        XCTAssertThrowsError(try NTFSWriteTransaction(device: device, safetyState: .init()))
    }

    func testAlignedWriteCanRollback() throws {
        let original = Data(repeating: 0x11, count: 1024)
        let device = MemoryBlockDevice(data: original, writable: true)
        let safe = NTFSVolumeSafetyState(
            isDirty: false,
            isHibernated: false,
            hasUnsupportedFeatures: false,
            checkCompleted: true,
            userEnabledExperimentalWrites: true
        )
        let transaction = try NTFSWriteTransaction(device: device, safetyState: safe)
        try transaction.write(offset: 512, data: Data(repeating: 0xAA, count: 512))
        XCTAssertEqual(try device.read(offset: 512, length: 512), Data(repeating: 0xAA, count: 512))
        try transaction.rollback()
        XCTAssertEqual(try device.read(offset: 0, length: 1024), original)
    }

    func testUnalignedWriteUsesSectorEnvelopeAndCanRollback() throws {
        let original = Data(repeating: 0x11, count: 1536)
        let device = MemoryBlockDevice(data: original, writable: true)
        let transaction = try NTFSWriteTransaction(device: device, safetyState: safeWriteState())
        try transaction.writeBytes(offset: 510, data: Data([0xAA, 0xBB, 0xCC, 0xDD]))
        XCTAssertEqual(try device.read(offset: 510, length: 4), Data([0xAA, 0xBB, 0xCC, 0xDD]))
        XCTAssertEqual(try device.read(offset: 0, length: 510), original.prefix(510))
        XCTAssertEqual(try device.read(offset: 514, length: 1022), original.suffix(1022))
        try transaction.rollback()
        XCTAssertEqual(try device.read(offset: 0, length: original.count), original)
    }

    func testWriteTransactionEnforcesRollbackBudget() throws {
        let original = Data(repeating: 0x11, count: 1536)
        let device = MemoryBlockDevice(data: original, writable: true)
        let transaction = try NTFSWriteTransaction(
            device: device,
            safetyState: safeWriteState(),
            maximumUndoBytes: 512
        )
        XCTAssertThrowsError(try transaction.writeBytes(offset: 510, data: Data(repeating: 0xAA, count: 4)))
        XCTAssertEqual(try device.read(offset: 0, length: original.count), original)
    }

    func testProtectsFixedFileRecordForDiskAndParsesItAgain() throws {
        let raw = makeFileRecord()
        let parsed = try NTFSFileRecord(data: raw, bytesPerSector: 512)
        let encoded = try NTFSMultiSectorRecordCodec.protect(parsed.fixedData, bytesPerSector: 512)
        XCTAssertEqual(encoded, raw)
        XCTAssertEqual(try NTFSFileRecord(data: encoded, bytesPerSector: 512), parsed)
    }

    func testReplacesResidentDataInImageWithoutChangingRecordSize() throws {
        let device = try makeWritableMFTImage()
        let volume = try NTFSVolumeReader(device: device)
        let writer = NTFSMetadataWriter(volume: volume, safetyState: safeWriteState())

        try writer.replaceResidentData(
            recordNumber: 42,
            expectedSequenceNumber: 7,
            expectedValue: Data("hello".utf8),
            replacement: Data("world".utf8)
        )

        let reread = try NTFSVolumeReader(device: device).readMFTRecord(42)
        XCTAssertEqual(reread.attributes.first?.value, Data("world".utf8))
        XCTAssertEqual(reread.sequenceNumber, 7)
        XCTAssertEqual(reread.recordNumber, 42)
    }

    func testResidentWriterRejectsStaleValueAndSystemRecord() throws {
        let device = try makeWritableMFTImage()
        let volume = try NTFSVolumeReader(device: device)
        let writer = NTFSMetadataWriter(volume: volume, safetyState: safeWriteState())

        XCTAssertThrowsError(try writer.replaceResidentData(
            recordNumber: 42,
            expectedSequenceNumber: 7,
            expectedValue: Data("stale".utf8),
            replacement: Data("world".utf8)
        ))
        XCTAssertThrowsError(try writer.replaceResidentData(
            recordNumber: 3,
            expectedSequenceNumber: 7,
            expectedValue: Data("hello".utf8),
            replacement: Data("world".utf8)
        ))
        XCTAssertEqual(try NTFSVolumeReader(device: device).readMFTRecord(42).attributes.first?.value, Data("hello".utf8))
    }

    func testVolumeInspectionBuildsSafeStateFromCleanConsistentImage() throws {
        let volume = try NTFSVolumeReader(device: makeWritableMFTImage())
        let inspection = try NTFSVolumeSafetyInspector.inspect(
            volume: volume,
            userEnabledExperimentalWrites: true
        )
        XCTAssertEqual(inspection.information, NTFSVolumeInformation(majorVersion: 3, minorVersion: 1, flags: 0))
        XCTAssertTrue(inspection.backupBootSectorMatches)
        XCTAssertTrue(inspection.mftMirrorMatches)
        XCTAssertEqual(inspection.hibernationState, .notPresent)
        XCTAssertNoThrow(try inspection.safetyState.validateWrites())
    }

    func testVolumeInspectionRejectsDirtyImage() throws {
        let volume = try NTFSVolumeReader(device: makeWritableMFTImage(volumeFlags: 1))
        let inspection = try NTFSVolumeSafetyInspector.inspect(
            volume: volume,
            userEnabledExperimentalWrites: true
        )
        XCTAssertTrue(inspection.safetyState.isDirty)
        XCTAssertThrowsError(try inspection.safetyState.validateWrites())
    }

    func testParsesResidentDirectoryIndexEntry() throws {
        let root = try NTFSDirectoryIndex.parseRoot(makeDirectoryIndexRoot(names: ["Example.txt"]))
        XCTAssertFalse(root.hasIndexAllocation)
        XCTAssertEqual(root.entries.count, 1)
        XCTAssertEqual(root.entries[0].fileName.name, "Example.txt")
        XCTAssertEqual(root.entries[0].recordNumber, 42)
        XCTAssertEqual(root.entries[0].sequenceNumber, 7)
    }

    func testParsesAllocationBackedIndexBufferAndRejectsTornSector() throws {
        let buffer = try makeIndexBuffer(names: ["LargeDirectoryItem.bin"])
        let entries = try NTFSDirectoryIndex.parseBuffer(buffer, bytesPerSector: 512)
        XCTAssertEqual(entries.map(\.fileName.name), ["LargeDirectoryItem.bin"])

        var torn = buffer
        torn[510] = 0
        XCTAssertThrowsError(try NTFSDirectoryIndex.parseBuffer(torn, bytesPerSector: 512))
    }

    func testAutomaticInspectionRejectsActiveHibernationFile() throws {
        let volume = try NTFSVolumeReader(device: makeWritableMFTImage(hasActiveHibernationFile: true))
        let inspection = try NTFSVolumeSafetyInspector.inspect(
            volume: volume,
            userEnabledExperimentalWrites: true
        )
        XCTAssertEqual(inspection.hibernationState, .active)
        XCTAssertThrowsError(try inspection.safetyState.validateWrites())
    }

    func testReadsMFTRecordZeroFromImage() throws {
        var image = Data(repeating: 0, count: 65_536)
        let boot = makeBootSector()
        put(boot, at: 0, in: &image)
        put(makeFileRecord(), at: 4 * 4096, in: &image)
        let volume = try NTFSVolumeReader(device: MemoryBlockDevice(data: image))
        let record = try volume.readMFTRecord(0)
        XCTAssertEqual(record.recordNumber, 42)
        XCTAssertEqual(record.attributes.first?.value, Data("hello".utf8))
    }

    private func makeBootSector() -> Data {
        var data = Data(repeating: 0, count: 512)
        put(Data("NTFS    ".utf8), at: 3, in: &data)
        putLE(512, byteCount: 2, at: 11, in: &data)
        data[13] = 8
        putLE(128, byteCount: 8, at: 40, in: &data)
        putLE(4, byteCount: 8, at: 48, in: &data)
        putLE(8, byteCount: 8, at: 56, in: &data)
        data[64] = UInt8(bitPattern: -10)
        data[68] = 1
        putLE(0x0123_4567_89AB_CDEF, byteCount: 8, at: 72, in: &data)
        data[510] = 0x55
        data[511] = 0xAA
        return data
    }

    private func safeWriteState() -> NTFSVolumeSafetyState {
        NTFSVolumeSafetyState(
            isDirty: false,
            isHibernated: false,
            hasUnsupportedFeatures: false,
            checkCompleted: true,
            userEnabledExperimentalWrites: true
        )
    }

    private func makeWritableMFTImage(
        volumeFlags: UInt16 = 0,
        hasActiveHibernationFile: Bool = false
    ) throws -> MemoryBlockDevice {
        var image = Data(repeating: 0, count: 65_536)
        let boot = makeBootSector()
        let mft = try makeMFTRecord()
        put(boot, at: 0, in: &image)
        put(boot, at: image.count - 512, in: &image)
        put(mft, at: 4 * 4096, in: &image)
        put(mft, at: 8 * 4096, in: &image)
        put(try makeVolumeRecord(flags: volumeFlags), at: 4 * 4096 + 3 * 1024, in: &image)
        let names = hasActiveHibernationFile ? ["hiberfil.sys"] : []
        put(try makeDirectoryRecord(indexRoot: makeDirectoryIndexRoot(names: names)), at: 4 * 4096 + 5 * 1024, in: &image)
        put(
            makeFileRecord(value: hasActiveHibernationFile ? "hibr!" : "hello"),
            at: 4 * 4096 + 42 * 1024,
            in: &image
        )
        return MemoryBlockDevice(data: image, writable: true)
    }

    private func makeDirectoryRecord(indexRoot: Data) throws -> Data {
        var fixed = Data(repeating: 0, count: 1024)
        put(Data("FILE".utf8), at: 0, in: &fixed)
        putLE(0x30, byteCount: 2, at: 4, in: &fixed)
        putLE(3, byteCount: 2, at: 6, in: &fixed)
        putLE(2, byteCount: 2, at: 16, in: &fixed)
        putLE(1, byteCount: 2, at: 18, in: &fixed)
        putLE(0x38, byteCount: 2, at: 20, in: &fixed)
        putLE(3, byteCount: 2, at: 22, in: &fixed)
        let attributeLength = (24 + indexRoot.count + 7) & ~7
        putLE(UInt64(0x38 + attributeLength + 4), byteCount: 4, at: 24, in: &fixed)
        putLE(1024, byteCount: 4, at: 28, in: &fixed)
        putLE(5, byteCount: 4, at: 44, in: &fixed)
        putLE(0xAAAA, byteCount: 2, at: 0x30, in: &fixed)
        putLE(0x1234, byteCount: 2, at: 0x32, in: &fixed)
        putLE(0x5678, byteCount: 2, at: 0x34, in: &fixed)
        putLE(0x1234, byteCount: 2, at: 510, in: &fixed)
        putLE(0x5678, byteCount: 2, at: 1022, in: &fixed)

        let attribute = 0x38
        putLE(0x90, byteCount: 4, at: attribute, in: &fixed)
        putLE(UInt64(attributeLength), byteCount: 4, at: attribute + 4, in: &fixed)
        putLE(1, byteCount: 2, at: attribute + 14, in: &fixed)
        putLE(UInt64(indexRoot.count), byteCount: 4, at: attribute + 16, in: &fixed)
        putLE(24, byteCount: 2, at: attribute + 20, in: &fixed)
        put(indexRoot, at: attribute + 24, in: &fixed)
        putLE(0xFFFF_FFFF, byteCount: 4, at: attribute + attributeLength, in: &fixed)
        return try NTFSMultiSectorRecordCodec.protect(fixed, bytesPerSector: 512)
    }

    private func makeDirectoryIndexRoot(names: [String]) -> Data {
        var entryBytes = Data()
        for name in names {
            let key = makeFileNameValue(name: name)
            let entryLength = (16 + key.count + 7) & ~7
            var entry = Data(repeating: 0, count: entryLength)
            putLE((UInt64(7) << 48) | 42, byteCount: 8, at: 0, in: &entry)
            putLE(UInt64(entryLength), byteCount: 2, at: 8, in: &entry)
            putLE(UInt64(key.count), byteCount: 2, at: 10, in: &entry)
            put(key, at: 16, in: &entry)
            entryBytes.append(entry)
        }
        var finalEntry = Data(repeating: 0, count: 16)
        putLE(16, byteCount: 2, at: 8, in: &finalEntry)
        putLE(2, byteCount: 2, at: 12, in: &finalEntry)
        entryBytes.append(finalEntry)

        var root = Data(repeating: 0, count: 32 + entryBytes.count)
        putLE(0x30, byteCount: 4, at: 0, in: &root)
        putLE(1, byteCount: 4, at: 4, in: &root)
        putLE(4096, byteCount: 4, at: 8, in: &root)
        root[12] = 1
        putLE(16, byteCount: 4, at: 16, in: &root)
        putLE(UInt64(16 + entryBytes.count), byteCount: 4, at: 20, in: &root)
        putLE(UInt64(16 + entryBytes.count), byteCount: 4, at: 24, in: &root)
        put(entryBytes, at: 32, in: &root)
        return root
    }

    private func makeIndexBuffer(names: [String]) throws -> Data {
        let root = makeDirectoryIndexRoot(names: names)
        let entries = root.subdata(in: 32..<root.count)
        var fixed = Data(repeating: 0, count: 4096)
        put(Data("INDX".utf8), at: 0, in: &fixed)
        putLE(0x28, byteCount: 2, at: 4, in: &fixed)
        putLE(9, byteCount: 2, at: 6, in: &fixed)
        putLE(40, byteCount: 4, at: 24, in: &fixed)
        putLE(UInt64(40 + entries.count), byteCount: 4, at: 28, in: &fixed)
        putLE(4096 - 24, byteCount: 4, at: 32, in: &fixed)
        putLE(0xAAAA, byteCount: 2, at: 0x28, in: &fixed)
        for sector in 0..<8 {
            let replacement = UInt64(0x1200 + sector)
            putLE(replacement, byteCount: 2, at: 0x2A + sector * 2, in: &fixed)
            putLE(replacement, byteCount: 2, at: (sector + 1) * 512 - 2, in: &fixed)
        }
        put(entries, at: 64, in: &fixed)
        return try NTFSMultiSectorRecordCodec.protect(fixed, bytesPerSector: 512)
    }

    private func makeFileNameValue(name: String) -> Data {
        let nameData = name.data(using: .utf16LittleEndian)!
        var value = Data(repeating: 0, count: 66 + nameData.count)
        putLE((UInt64(1) << 48) | 5, byteCount: 8, at: 0, in: &value)
        putLE(5, byteCount: 8, at: 40, in: &value)
        putLE(5, byteCount: 8, at: 48, in: &value)
        value[64] = UInt8(nameData.count / 2)
        value[65] = 1
        put(nameData, at: 66, in: &value)
        return value
    }

    private func makeVolumeRecord(flags: UInt16) throws -> Data {
        var fixed = Data(repeating: 0, count: 1024)
        put(Data("FILE".utf8), at: 0, in: &fixed)
        putLE(0x30, byteCount: 2, at: 4, in: &fixed)
        putLE(3, byteCount: 2, at: 6, in: &fixed)
        putLE(1, byteCount: 2, at: 16, in: &fixed)
        putLE(1, byteCount: 2, at: 18, in: &fixed)
        putLE(0x38, byteCount: 2, at: 20, in: &fixed)
        putLE(1, byteCount: 2, at: 22, in: &fixed)
        putLE(0x84, byteCount: 4, at: 24, in: &fixed)
        putLE(1024, byteCount: 4, at: 28, in: &fixed)
        putLE(3, byteCount: 4, at: 44, in: &fixed)
        putLE(0xAAAA, byteCount: 2, at: 0x30, in: &fixed)
        putLE(0x1234, byteCount: 2, at: 0x32, in: &fixed)
        putLE(0x5678, byteCount: 2, at: 0x34, in: &fixed)
        putLE(0x1234, byteCount: 2, at: 510, in: &fixed)
        putLE(0x5678, byteCount: 2, at: 1022, in: &fixed)

        let attribute = 0x38
        putLE(0x70, byteCount: 4, at: attribute, in: &fixed)
        putLE(40, byteCount: 4, at: attribute + 4, in: &fixed)
        putLE(1, byteCount: 2, at: attribute + 14, in: &fixed)
        putLE(12, byteCount: 4, at: attribute + 16, in: &fixed)
        putLE(24, byteCount: 2, at: attribute + 20, in: &fixed)
        fixed[attribute + 24 + 8] = 3
        fixed[attribute + 24 + 9] = 1
        putLE(UInt64(flags), byteCount: 2, at: attribute + 24 + 10, in: &fixed)
        putLE(0xFFFF_FFFF, byteCount: 4, at: attribute + 40, in: &fixed)
        return try NTFSMultiSectorRecordCodec.protect(fixed, bytesPerSector: 512)
    }

    private func makeMFTRecord() throws -> Data {
        var fixed = Data(repeating: 0, count: 1024)
        put(Data("FILE".utf8), at: 0, in: &fixed)
        putLE(0x30, byteCount: 2, at: 4, in: &fixed)
        putLE(3, byteCount: 2, at: 6, in: &fixed)
        putLE(1, byteCount: 2, at: 16, in: &fixed)
        putLE(1, byteCount: 2, at: 18, in: &fixed)
        putLE(0x38, byteCount: 2, at: 20, in: &fixed)
        putLE(1, byteCount: 2, at: 22, in: &fixed)
        putLE(0x84, byteCount: 4, at: 24, in: &fixed)
        putLE(1024, byteCount: 4, at: 28, in: &fixed)
        putLE(0, byteCount: 4, at: 44, in: &fixed)

        putLE(0xAAAA, byteCount: 2, at: 0x30, in: &fixed)
        putLE(0x1234, byteCount: 2, at: 0x32, in: &fixed)
        putLE(0x5678, byteCount: 2, at: 0x34, in: &fixed)
        putLE(0x1234, byteCount: 2, at: 510, in: &fixed)
        putLE(0x5678, byteCount: 2, at: 1022, in: &fixed)

        let attribute = 0x38
        putLE(0x80, byteCount: 4, at: attribute, in: &fixed)
        putLE(72, byteCount: 4, at: attribute + 4, in: &fixed)
        fixed[attribute + 8] = 1
        putLE(1, byteCount: 2, at: attribute + 14, in: &fixed)
        putLE(0, byteCount: 8, at: attribute + 16, in: &fixed)
        putLE(11, byteCount: 8, at: attribute + 24, in: &fixed)
        putLE(64, byteCount: 2, at: attribute + 32, in: &fixed)
        putLE(49_152, byteCount: 8, at: attribute + 40, in: &fixed)
        putLE(49_152, byteCount: 8, at: attribute + 48, in: &fixed)
        putLE(49_152, byteCount: 8, at: attribute + 56, in: &fixed)
        put(Data([0x11, 0x0C, 0x04, 0x00]), at: attribute + 64, in: &fixed)
        putLE(0xFFFF_FFFF, byteCount: 4, at: attribute + 72, in: &fixed)
        return try NTFSMultiSectorRecordCodec.protect(fixed, bytesPerSector: 512)
    }

    private func makeFileRecord(value: String = "hello") -> Data {
        var data = Data(repeating: 0, count: 1024)
        put(Data("FILE".utf8), at: 0, in: &data)
        putLE(0x30, byteCount: 2, at: 4, in: &data)
        putLE(3, byteCount: 2, at: 6, in: &data)
        putLE(7, byteCount: 2, at: 16, in: &data)
        putLE(1, byteCount: 2, at: 18, in: &data)
        putLE(0x38, byteCount: 2, at: 20, in: &data)
        putLE(1, byteCount: 2, at: 22, in: &data)
        putLE(0x60 + 32, byteCount: 4, at: 24, in: &data)
        putLE(1024, byteCount: 4, at: 28, in: &data)
        putLE(42, byteCount: 4, at: 44, in: &data)

        putLE(0xAAAA, byteCount: 2, at: 0x30, in: &data)
        putLE(0x1234, byteCount: 2, at: 0x32, in: &data)
        putLE(0x5678, byteCount: 2, at: 0x34, in: &data)
        putLE(0xAAAA, byteCount: 2, at: 510, in: &data)
        putLE(0xAAAA, byteCount: 2, at: 1022, in: &data)

        let attribute = 0x38
        putLE(0x80, byteCount: 4, at: attribute, in: &data)
        putLE(32, byteCount: 4, at: attribute + 4, in: &data)
        data[attribute + 8] = 0
        putLE(1, byteCount: 2, at: attribute + 14, in: &data)
        let valueData = Data(value.utf8)
        putLE(UInt64(valueData.count), byteCount: 4, at: attribute + 16, in: &data)
        putLE(24, byteCount: 2, at: attribute + 20, in: &data)
        put(valueData, at: attribute + 24, in: &data)
        putLE(0xFFFF_FFFF, byteCount: 4, at: attribute + 32, in: &data)
        return data
    }

    private func putLE(_ value: UInt64, byteCount: Int, at offset: Int, in data: inout Data) {
        for index in 0..<byteCount { data[offset + index] = UInt8(truncatingIfNeeded: value >> UInt64(index * 8)) }
    }

    private func put(_ value: Data, at offset: Int, in data: inout Data) {
        data.replaceSubrange(offset..<(offset + value.count), with: value)
    }
}
