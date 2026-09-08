// SPDX-License-Identifier: MIT

import Foundation

public struct NTFSVolumeSafetyState: Equatable {
    public var isDirty: Bool
    public var isHibernated: Bool
    public var hasUnsupportedFeatures: Bool
    public var checkCompleted: Bool
    public var userEnabledExperimentalWrites: Bool

    public init(
        isDirty: Bool = true,
        isHibernated: Bool = false,
        hasUnsupportedFeatures: Bool = false,
        checkCompleted: Bool = false,
        userEnabledExperimentalWrites: Bool = false
    ) {
        self.isDirty = isDirty
        self.isHibernated = isHibernated
        self.hasUnsupportedFeatures = hasUnsupportedFeatures
        self.checkCompleted = checkCompleted
        self.userEnabledExperimentalWrites = userEnabledExperimentalWrites
    }

    public func validateWrites() throws {
        guard userEnabledExperimentalWrites else { throw NTFSError.readOnly("experimental writes are not enabled") }
        guard checkCompleted else { throw NTFSError.readOnly("volume check has not completed") }
        guard !isDirty else { throw NTFSError.readOnly("volume is dirty") }
        guard !isHibernated else { throw NTFSError.readOnly("Windows hibernation state is present") }
        guard !hasUnsupportedFeatures else { throw NTFSError.readOnly("unsupported NTFS features are present") }
    }
}

public final class NTFSWriteTransaction {
    private struct UndoWrite {
        let offset: UInt64
        let data: Data
    }

    private let device: NTFSBlockDevice
    private let maximumUndoBytes: Int
    private var undoWrites: [UndoWrite] = []
    private var undoBytes = 0
    private var finished = false

    public init(
        device: NTFSBlockDevice,
        safetyState: NTFSVolumeSafetyState,
        maximumUndoBytes: Int = 16 * 1024 * 1024
    ) throws {
        guard device.isWritable else { throw NTFSError.readOnly("block device is read-only") }
        guard device.sectorSize > 0, maximumUndoBytes >= device.sectorSize else {
            throw NTFSError.readOnly("invalid write transaction limits")
        }
        try safetyState.validateWrites()
        self.device = device
        self.maximumUndoBytes = maximumUndoBytes
    }

    /// Writes complete sectors and verifies the bytes before the transaction can commit.
    public func write(offset: UInt64, data: Data) throws {
        guard !finished else { throw NTFSError.readOnly("transaction is already finished") }
        guard !data.isEmpty, offset % UInt64(device.sectorSize) == 0, data.count % device.sectorSize == 0 else {
            throw NTFSError.readOnly("writes must be aligned to complete sectors")
        }
        guard data.count <= maximumUndoBytes - undoBytes else {
            throw NTFSError.readOnly("transaction exceeds the rollback memory limit")
        }
        let original = try device.read(offset: offset, length: data.count)
        undoWrites.append(UndoWrite(offset: offset, data: original))
        undoBytes += original.count
        do {
            try device.write(offset: offset, data: data)
            guard try device.read(offset: offset, length: data.count) == data else {
                throw NTFSError.writeVerificationFailed(offset: offset, length: data.count)
            }
        } catch {
            // A failing device may have performed a partial write. Restore every captured
            // sector, including this one, before returning the original error.
            try? rollback()
            throw error
        }
    }

    /// Safely patches an arbitrary byte range using sector-sized read-modify-write I/O.
    public func writeBytes(offset: UInt64, data: Data) throws {
        guard !data.isEmpty else { throw NTFSError.readOnly("empty writes are not allowed") }
        let sector = UInt64(device.sectorSize)
        let alignedStart = offset - (offset % sector)
        let (unroundedEnd, overflow) = offset.addingReportingOverflow(UInt64(data.count))
        guard !overflow else { throw NTFSError.outOfBounds(offset: offset, length: data.count) }
        let remainder = unroundedEnd % sector
        let padding = remainder == 0 ? 0 : sector - remainder
        let (alignedEnd, endOverflow) = unroundedEnd.addingReportingOverflow(padding)
        guard !endOverflow, alignedEnd >= alignedStart,
              alignedEnd - alignedStart <= UInt64(Int.max) else {
            throw NTFSError.outOfBounds(offset: offset, length: data.count)
        }

        let envelopeLength = Int(alignedEnd - alignedStart)
        var envelope = try device.read(offset: alignedStart, length: envelopeLength)
        let start = Int(offset - alignedStart)
        envelope.replaceSubrange(start..<(start + data.count), with: data)
        try write(offset: alignedStart, data: envelope)
    }

    public func commit() throws {
        guard !finished else { return }
        try device.synchronize()
        undoWrites.removeAll()
        undoBytes = 0
        finished = true
    }

    public func rollback() throws {
        guard !finished else { return }
        for undo in undoWrites.reversed() {
            try device.write(offset: undo.offset, data: undo.data)
        }
        try device.synchronize()
        undoWrites.removeAll()
        undoBytes = 0
        finished = true
    }
}
