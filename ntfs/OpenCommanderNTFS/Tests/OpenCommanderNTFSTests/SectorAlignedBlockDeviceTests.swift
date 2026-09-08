// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import OpenCommanderNTFS

final class SectorAlignedBlockDeviceTests: XCTestCase {
    func testBootReadOn4KSectors() throws {
        let raw = StrictDevice()
        let device = try SectorAlignedBlockDevice(device: raw)
        XCTAssertEqual(try device.read(offset: 0, length: 512), raw.storage.prefix(512))
        XCTAssertEqual(raw.reads, [4096])
    }

    func testUnalignedReadAcrossSectorsAndChunkBoundary() throws {
        let raw = StrictDevice()
        let device = try SectorAlignedBlockDevice(device: raw, maximumTransferSize: 5000)
        XCTAssertEqual(try device.read(offset: 4091, length: 4105), raw.storage.subdata(in: 4091..<8196))
        XCTAssertEqual(raw.reads, [4096, 4096, 4096])
    }

    func testPartialWritesPreserveBothNeighbors() throws {
        let raw = StrictDevice()
        let before = raw.storage
        let device = try SectorAlignedBlockDevice(device: raw, maximumTransferSize: 4096)
        let replacement = Data(repeating: 0xAB, count: 4105)
        try device.write(offset: 4091, data: replacement)
        XCTAssertEqual(raw.storage.prefix(4091), before.prefix(4091))
        XCTAssertEqual(raw.storage.subdata(in: 4091..<8196), replacement)
        XCTAssertEqual(raw.storage.suffix(from: 8196), before.suffix(from: 8196))
        XCTAssertEqual(raw.writes, [4096, 4096, 4096])
        XCTAssertEqual(raw.reads, [4096, 4096])
    }

    func testSlicedDataAndFinalByte() throws {
        let raw = StrictDevice()
        let device = try SectorAlignedBlockDevice(device: raw)
        let source = Data([1, 2, 3, 4])[2..<4]
        try device.write(offset: raw.size - 2, data: source)
        XCTAssertEqual(try device.read(offset: raw.size - 2, length: 2), Data([3, 4]))
    }

    func testAlignedWriteDoesNotReadAndChunksTransfers() throws {
        let raw = StrictDevice()
        let device = try SectorAlignedBlockDevice(device: raw, maximumTransferSize: 4096)
        let replacement = Data(repeating: 42, count: 8192)
        try device.write(offset: 0, data: replacement)
        XCTAssertEqual(raw.reads, [])
        XCTAssertEqual(raw.writes, [4096, 4096])
        XCTAssertEqual(raw.storage.prefix(8192), replacement)
    }

    func testEmptyIOAtEndDoesNotTouchResource() throws {
        let raw = StrictDevice()
        let device = try SectorAlignedBlockDevice(device: raw)
        XCTAssertEqual(try device.read(offset: raw.size, length: 0), Data())
        try device.write(offset: raw.size, data: Data())
        XCTAssertTrue(raw.reads.isEmpty)
        XCTAssertTrue(raw.writes.isEmpty)
    }

    func testBoundsAndOverflowRejectedBeforeIO() throws {
        let raw = StrictDevice()
        let device = try SectorAlignedBlockDevice(device: raw)
        XCTAssertThrowsError(try device.read(offset: UInt64.max, length: 1))
        XCTAssertThrowsError(try device.read(offset: 0, length: -1))
        XCTAssertThrowsError(try device.read(offset: raw.size - 1, length: 2))
        XCTAssertThrowsError(try device.write(offset: raw.size, data: Data([1])))
        XCTAssertTrue(raw.reads.isEmpty)
        XCTAssertTrue(raw.writes.isEmpty)
    }

    func testInvalidGeometryIsRejected() {
        for sector in [0, -1, 511, 513, Int.max] {
            XCTAssertThrowsError(try SectorAlignedBlockDevice(device: StrictDevice(sector: sector)))
        }
        // Do not silently extend a physical-sector transfer beyond a partition.
        XCTAssertThrowsError(try SectorAlignedBlockDevice(device: StrictDevice(size: 4608)))
        XCTAssertThrowsError(try SectorAlignedBlockDevice(device: StrictDevice(size: 0)))
        XCTAssertThrowsError(try SectorAlignedBlockDevice(device: StrictDevice(), maximumTransferSize: 512))
    }

    func test512ByteSectors() throws {
        let raw = StrictDevice(size: 1536, sector: 512)
        let device = try SectorAlignedBlockDevice(device: raw)
        try device.write(offset: 1535, data: Data([42]))
        XCTAssertEqual(try device.read(offset: 1535, length: 1), Data([42]))
        XCTAssertEqual(raw.writes, [512])
    }

    func testReadonlyRefusesBeforeReading() throws {
        let raw = StrictDevice()
        let device = try SectorAlignedBlockDevice(device: raw)
        raw.isWritable = false
        XCTAssertThrowsError(try device.write(offset: 5, data: Data([1]))) { error in
            guard case NTFSError.readOnly = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertTrue(raw.reads.isEmpty)
        XCTAssertTrue(raw.writes.isEmpty)
    }

    func testShortReadStopsReadModifyWrite() throws {
        let raw = StrictDevice()
        raw.shortenReads = true
        let device = try SectorAlignedBlockDevice(device: raw)
        XCTAssertThrowsError(try device.write(offset: 5, data: Data([1]))) { error in
            XCTAssertEqual(error as? NTFSError, .shortRead(expected: 4096, actual: 4095))
        }
        XCTAssertTrue(raw.writes.isEmpty)
        XCTAssertThrowsError(try device.read(offset: 5, length: 1))
    }

    func testWriteAndFlushErrorsPropagate() throws {
        let raw = StrictDevice()
        let device = try SectorAlignedBlockDevice(device: raw)
        raw.failWrites = true
        XCTAssertThrowsError(try device.write(offset: 0, data: Data(repeating: 1, count: 8192))) { error in
            XCTAssertEqual(error as? NTFSError, .shortWrite(expected: 8192, actual: 0))
        }
        raw.failFlush = true
        XCTAssertThrowsError(try device.synchronize())
        XCTAssertEqual(raw.flushes, 1)
        raw.failFlush = false
        try device.synchronize()
        XCTAssertEqual(raw.flushes, 2)
    }

    func testConcurrentPartialWritesDoNotLoseNeighborUpdates() throws {
        let raw = StrictDevice()
        raw.delayReads = true
        let device = try SectorAlignedBlockDevice(device: raw)
        DispatchQueue.concurrentPerform(iterations: 32) { index in
            do {
                try device.write(offset: UInt64(index), data: Data([UInt8(200 + index)]))
            } catch {
                XCTFail("Concurrent write failed: \(error)")
            }
        }
        XCTAssertEqual(try device.read(offset: 0, length: 32), Data((200..<232).map(UInt8.init)))
        XCTAssertEqual(raw.writes.count, 32)
    }
}

/// Deliberately rejects byte-range I/O unlike MemoryBlockDevice.
private final class StrictDevice: NTFSBlockDevice {
    var storage: Data
    let sectorSize: Int
    var size: UInt64 { UInt64(storage.count) }
    var isWritable = true
    var reads: [Int] = []
    var writes: [Int] = []
    var flushes = 0
    var shortenReads = false
    var failWrites = false
    var failFlush = false
    var delayReads = false

    init(size: Int = 16384, sector: Int = 4096) {
        storage = Data((0..<size).map { UInt8($0 % 251) })
        sectorSize = sector
    }

    private func check(offset: UInt64, length: Int) throws {
        guard offset % UInt64(sectorSize) == 0, length > 0, length % sectorSize == 0,
              offset <= size, UInt64(length) <= size - offset else {
            throw NTFSError.outOfBounds(offset: offset, length: length)
        }
    }

    func read(offset: UInt64, length: Int) throws -> Data {
        try check(offset: offset, length: length)
        reads.append(length)
        let result = storage.subdata(in: Int(offset)..<(Int(offset) + length - (shortenReads ? 1 : 0)))
        // Give other callers an opportunity to race the read-modify-write.
        if delayReads { Thread.sleep(forTimeInterval: 0.001) }
        return result
    }

    func write(offset: UInt64, data: Data) throws {
        try check(offset: offset, length: data.count)
        guard isWritable else { throw NTFSError.readOnly("test device") }
        writes.append(data.count)
        if failWrites { throw NTFSError.shortWrite(expected: data.count, actual: 0) }
        storage.replaceSubrange(Int(offset)..<(Int(offset) + data.count), with: data)
    }

    func synchronize() throws {
        flushes += 1
        if failFlush { throw POSIXError(.EIO) }
    }
}
