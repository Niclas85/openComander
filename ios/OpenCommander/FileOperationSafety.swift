import Foundation
import CryptoKit

/// File operations kept separate from UIKit so failure paths can be tested with fixtures.
enum SafeFileOperations {
    static func exists(_ url: URL) -> Bool {
        // Includes dangling symlinks: these are still occupied destination names.
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    static func conflict(_ url: URL) -> NSError {
        NSError(domain: "OpenCommander.FileSafety", code: 1,
                userInfo: [NSLocalizedDescriptionKey: L10n.get("undo_changed") + "\n" + url.path])
    }

    static func snapshot(_ url: URL) throws -> Data {
        let fm = FileManager.default
        var digest = SHA256()
        func field(_ string: String) {
            let data = Data(string.utf8)
            digest.update(data: Data("\(data.count):".utf8))
            digest.update(data: data)
        }
        func visit(_ item: URL) throws {
            let attributes = try fm.attributesOfItem(atPath: item.path)
            guard let type = attributes[.type] as? FileAttributeType else { throw conflict(item) }
            field(item.lastPathComponent)
            field(type.rawValue)
            field(String(describing: attributes[.systemFileNumber]))
            field(String((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0))
            if type == .typeDirectory {
                let children = try fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                field(String(children.count))
                for child in children { try visit(child) }
            } else if type == .typeSymbolicLink {
                field(try fm.destinationOfSymbolicLink(atPath: item.path))
            } else if type == .typeRegular {
                var content = SHA256()
                let handle = try FileHandle(forReadingFrom: item)
                defer { try? handle.close() }
                while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
                    content.update(data: data)
                }
                digest.update(data: Data(content.finalize()))
            } else {
                throw conflict(item)
            }
        }
        try visit(url)
        return Data(digest.finalize())
    }

    /// Finish copying before displacing the old target. Staging is on the target volume.
    static func copyReplacing(source: URL, destination: URL, replace: Bool,
                              copy: (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) },
                              publish: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }) throws -> URL? {
        let fm = FileManager.default
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".OpenCommanderTransfer-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        let payload = staging.appendingPathComponent("payload")
        let backup = staging.appendingPathComponent("previous")
        var displaced = false
        var keepRecovery = false
        defer {
            if !keepRecovery { try? fm.removeItem(at: staging) }
        }
        do {
            try copy(source, payload)
            if exists(destination) {
                guard replace else { throw conflict(destination) }
                try fm.moveItem(at: destination, to: backup)
                displaced = true
            }
            try publish(payload, destination)
            keepRecovery = displaced
            return displaced ? backup : nil
        } catch {
            if displaced {
                // Never remove an unexpected destination just to restore the previous file.
                do {
                    guard !exists(destination) else { throw conflict(destination) }
                    try fm.moveItem(at: backup, to: destination)
                } catch let recoveryError {
                    keepRecovery = true
                    throw NSError(domain: "OpenCommander.FileSafety", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey:
                                    L10n.get("recovery_retained", staging.path) + "\n" + recoveryError.localizedDescription,
                                             NSUnderlyingErrorKey: error])
                }
            }
            throw error
        }
    }
}

final class FileUndoRecord {
    let source: URL
    let destination: URL
    let replacedBackup: URL?
    private let snapshot: Data?
    private var destinationReverted = false
    private(set) var completed = false

    init(source: URL, destination: URL, replacedBackup: URL?) {
        self.source = source
        self.destination = destination
        self.replacedBackup = replacedBackup
        // A read failure disables undo; it must never roll back an already completed move.
        snapshot = try? SafeFileOperations.snapshot(destination)
    }

    func undo(move: Bool) throws {
        if completed { return }
        let fm = FileManager.default
        if !destinationReverted {
            guard let snapshot, snapshot == (try SafeFileOperations.snapshot(destination)) else {
                throw SafeFileOperations.conflict(destination)
            }
            if move {
                guard !SafeFileOperations.exists(source) else { throw SafeFileOperations.conflict(source) }
                try fm.moveItem(at: destination, to: source)
            } else {
                // Retain the current version even if an external writer raced the snapshot.
                let recovery = destination.deletingLastPathComponent()
                    .appendingPathComponent(".OpenCommanderUndo-\(UUID().uuidString)", isDirectory: true)
                try fm.createDirectory(at: recovery, withIntermediateDirectories: false)
                try fm.moveItem(at: destination, to: recovery.appendingPathComponent(destination.lastPathComponent))
            }
            destinationReverted = true
        }
        if let backup = replacedBackup {
            guard !SafeFileOperations.exists(destination) else { throw SafeFileOperations.conflict(destination) }
            try fm.moveItem(at: backup, to: destination)
        }
        completed = true
    }
}
