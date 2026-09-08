import Foundation
import UniformTypeIdentifiers

/// Owns provider files and security scopes until the transfer (including any
/// conflict dialog) finishes. Never delete a provider's original on cleanup.
final class FileDropBatch: @unchecked Sendable {
    struct Item {
        let url: URL
        let isOriginal: Bool
    }
    // Foundation calls providers on arbitrary queues. Protect all mutable
    // state; consumers receive snapshots only after loading has completed.
    private let lock = NSLock()
    private var storedItems: [Item] = []
    var items: [Item] { lock.lock(); defer { lock.unlock() }; return storedItems }
    private var scopes: [URL] = []
    private var storedStagingDirectory: URL?
    private var released = false
    var stagingDirectory: URL? { lock.lock(); defer { lock.unlock() }; return storedStagingDirectory }

    func retainOriginal(_ url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !released else { throw FileDropTransfer.error("The file drop was cancelled.") }
        guard url.isFileURL else { throw FileDropTransfer.error("Only local files and folders can be dropped here.") }
        let scoped = url.startAccessingSecurityScopedResource()
        if scoped { scopes.append(url) }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FileDropTransfer.error("The dropped file is unavailable: \(url.lastPathComponent)")
        }
        if !storedItems.contains(where: { $0.url.resolvingSymlinksInPath() == url.resolvingSymlinksInPath() }) {
            storedItems.append(Item(url: url, isOriginal: true))
        }
    }

    func retainTemporary(_ url: URL, suggestedName: String?) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !released else { throw FileDropTransfer.error("The file drop was cancelled.") }
        guard url.isFileURL else { throw FileDropTransfer.error("The application did not provide a local file.") }
        let fm = FileManager.default
        if storedStagingDirectory == nil {
            let root = fm.temporaryDirectory.appendingPathComponent("OpenCommanderDrop-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: root, withIntermediateDirectories: false)
            storedStagingDirectory = root
        }
        // Separate subdirectories preserve names of identically named drops.
        let container = storedStagingDirectory!.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: container, withIntermediateDirectories: false)
        let suggested = suggestedName ?? url.lastPathComponent
        let safe = FileDropTransfer.safeName(suggested, fallback: url.lastPathComponent)
        let destination = container.appendingPathComponent(safe)
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        // Must finish inside the provider callback: temporary URLs can vanish
        // as soon as that callback returns. Copy, never move the provider file.
        try fm.copyItem(at: url, to: destination)
        storedItems.append(Item(url: destination, isOriginal: false))
    }

    func releaseResources() {
        lock.lock()
        defer { lock.unlock() }
        guard !released else { return }
        released = true
        for url in scopes { url.stopAccessingSecurityScopedResource() }
        scopes.removeAll()
        if let storedStagingDirectory { try? FileManager.default.removeItem(at: storedStagingDirectory) }
    }

    deinit { releaseResources() }
}

enum FileDropTransfer {
    private final class CompletionState: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false
        var isCompleted: Bool { lock.lock(); defer { lock.unlock() }; return completed }
        func finishOnce() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if completed { return false }
            completed = true
            return true
        }
    }
    static func error(_ message: String) -> NSError {
        NSError(domain: "OpenCommander.FileDrop", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func safeName(_ name: String, fallback: String) -> String {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != ".", value != "..", !value.contains("/"),
              !value.contains("\\"), !value.contains("\0") else {
            return fallback.isEmpty || fallback == "." || fallback == ".." ? "Dropped File" : (fallback as NSString).lastPathComponent
        }
        if (value as NSString).pathExtension.isEmpty, !(fallback as NSString).pathExtension.isEmpty {
            return value + "." + (fallback as NSString).pathExtension
        }
        return value
    }

    static func fileType(_ provider: NSItemProvider) -> String? {
        provider.registeredTypeIdentifiers.first { identifier in
            guard let type = UTType(identifier), !type.conforms(to: .url) else { return false }
            return type.conforms(to: .content) || type.conforms(to: .data) || type.conforms(to: .directory)
        }
    }

    static func canLoad(_ provider: NSItemProvider) -> Bool {
        provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) || fileType(provider) != nil
    }

    static func provider(for url: URL) -> NSItemProvider {
        let provider = NSItemProvider(object: url as NSURL)
        provider.suggestedName = url.lastPathComponent
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey])
        let type = values?.isDirectory == true ? UTType.folder : (values?.contentType ?? .data)
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: .openInPlace,
                                            visibility: .all) { completion in
            completion(url, false, nil)
            return nil
        }
        return provider
    }

    /// Load in source order, fail the whole preparation if any item fails.
    /// No destination mutation or deletion occurs during provider loading.
    static func load(_ providers: [NSItemProvider], timeout: TimeInterval = 120,
                     completion: @escaping (Result<FileDropBatch, Error>) -> Void) {
        let batch = FileDropBatch()
        let state = CompletionState()
        func finish(_ result: Result<FileDropBatch, Error>) {
            guard state.finishOnce() else { return }
            if case .failure = result { batch.releaseResources() }
            DispatchQueue.main.async { completion(result) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            finish(.failure(error("The source application did not finish providing the files. Please try again.")))
        }
        func next(_ index: Int) {
            guard !state.isCompleted else { return }
            guard index < providers.count else {
                finish(batch.items.isEmpty ? .failure(error("No readable files were dropped.")) : .success(batch))
                return
            }
            let provider = providers[index]
            func representation() {
                guard let type = fileType(provider) else {
                    finish(.failure(error("The application did not provide a supported file representation.")))
                    return
                }
                provider.loadInPlaceFileRepresentation(forTypeIdentifier: type) { url, inPlace, failure in
                    guard !state.isCompleted else { return }
                    guard let url else {
                        finish(.failure(failure ?? error("Could not load the dropped file.")))
                        return
                    }
                    do {
                        if inPlace { try batch.retainOriginal(url) }
                        else { try batch.retainTemporary(url, suggestedName: provider.suggestedName) }
                        // The next provider may complete on another queue; only
                        // one callback touches the batch at a time.
                        next(index + 1)
                    } catch { finish(.failure(error)) }
                }
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                let hasFallback = fileType(provider) != nil
                provider.loadObject(ofClass: NSURL.self) { object, failure in
                    guard !state.isCompleted else { return }
                    if let url = object as? URL, url.isFileURL {
                        do { try batch.retainOriginal(url); next(index + 1) }
                        catch { finish(.failure(error)) }
                    } else if hasFallback {
                        representation()
                    } else {
                        finish(.failure(failure ?? error("The dropped URL is not a local file.")))
                    }
                }
            } else { representation() }
        }
        next(0)
    }
}
