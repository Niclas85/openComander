// SPDX-License-Identifier: MIT

import Foundation
import FSKit
import OpenCommanderNTFS
import OSLog

private let ntfsLogger = Logger(subsystem: "com.github.niklaus85.OpenCommander.NTFS", category: "FSKit")

@objc
final class OpenCommanderNTFSFileSystem: FSUnaryFileSystem & FSUnaryFileSystemOperations & FSManageableResourceMaintenanceOperations {
    private var loadedResource: FSBlockDeviceResource?
    private let resourceLock = NSLock()

    func probeResource(
        resource: FSResource,
        replyHandler: @escaping (FSProbeResult?, (any Error)?) -> Void
    ) {
        guard let blockResource = resource as? FSBlockDeviceResource else {
            replyHandler(.notRecognized, nil)
            return
        }
        do {
            let device = try FSKitBlockDevice(resource: blockResource)
            let boot = try NTFSBootSector(data: device.read(offset: 0, length: 512))
            let serial = String(format: "%016llX", boot.volumeSerialNumber)
            let containerID = FSContainerIdentifier(uuid: Self.uuid(for: boot.volumeSerialNumber))
            // Recognized, rather than usable: FSKit must not replace macOS's reader until the
            // complete volume and crash-recovery layers pass the image test suite.
            #if OPENCOMMANDER_NTFS3G_EXPERIMENTAL
            resourceLock.lock()
            loadedResource = blockResource
            resourceLock.unlock()
            replyHandler(.usable(name: "OpenCommander NTFS \(serial)", containerID: containerID), nil)
            #else
            replyHandler(.recognized(name: "OpenCommander NTFS \(serial)", containerID: containerID), nil)
            #endif
        } catch let error as NTFSError {
            ntfsLogger.debug("NTFS probe rejected resource: \(error.description, privacy: .public)")
            replyHandler(.notRecognized, nil)
        } catch {
            replyHandler(nil, error)
        }
    }

    func loadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler: @escaping (FSVolume?, (any Error)?) -> Void
    ) {
        guard let block = resource as? FSBlockDeviceResource else {
            replyHandler(nil, POSIXError(.EINVAL))
            return
        }
        #if OPENCOMMANDER_NTFS3G_EXPERIMENTAL
        do {
            let device = try FSKitBlockDevice(resource: block)
            let boot = try NTFSBootSector(data: device.read(offset: 0, length: 512))
            let flags = options.taskOptions.flatMap { $0.split(separator: ",").map(String.init) }
            let readOnly = flags.contains("ro") || flags.contains("rdonly") || flags.contains("--rdonly") || !block.isWritable
            let volume = try NTFS3GVolume(resource: block, readOnly: readOnly, serial: boot.volumeSerialNumber)
            resourceLock.lock()
            loadedResource = block
            resourceLock.unlock()
            containerStatus = .ready
            replyHandler(volume, nil)
        } catch { replyHandler(nil, error) }
        #else
        // Production remains fail-closed until the FSKit end-to-end and recovery
        // gates have passed. The prototype build is explicitly opt-in.
        replyHandler(nil, POSIXError(.ENOTSUP))
        #endif
    }

    func unloadResource(resource: FSResource, options: FSTaskOptions) async throws {
        resourceLock.withLock { loadedResource = nil }
        containerStatus = .notReady(status: POSIXError(.ENXIO))
    }

    func startCheck(task: FSTask, options: FSTaskOptions) throws -> Progress {
        #if OPENCOMMANDER_NTFS3G_EXPERIMENTAL
        let block = resourceLock.withLock { loadedResource }
        guard let block else { throw POSIXError(.ENXIO) }
        let progress = Progress(totalUnitCount: 1)
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: Error?
            do {
                let device = try FSKitBlockDevice(resource: block)
                let volume = try NTFSVolumeReader(device: device)
                let inspection = try NTFSVolumeSafetyInspector.inspect(volume: volume, userEnabledExperimentalWrites: true)
                try inspection.safetyState.validateWrites()
            } catch { failure = error }
            progress.completedUnitCount = 1
            task.didComplete(error: failure)
        }
        return progress
        #else
        throw POSIXError(.ENOTSUP)
        #endif
    }

    func startFormat(task: FSTask, options: FSTaskOptions) throws -> Progress {
        throw POSIXError(.ENOTSUP)
    }

    private static func uuid(for serial: UInt64) -> UUID {
        let high = UInt32(truncatingIfNeeded: serial >> 32)
        let middle = UInt16(truncatingIfNeeded: serial >> 16)
        let low = UInt16(truncatingIfNeeded: serial)
        let text = String(format: "%08X-%04X-4%03X-8A11-%012llX", high, middle, low & 0x0FFF, serial & 0x0000_FFFF_FFFF_FFFF)
        return UUID(uuidString: text) ?? UUID()
    }
}
