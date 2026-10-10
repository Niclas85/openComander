#if targetEnvironment(macCatalyst)
import UIKit
import UniformTypeIdentifiers
import ZIPFoundation

private final class OneDriveCell: UITableViewCell {
    var activateEntry: (() -> Void)?
    override func accessibilityActivate() -> Bool {
        guard let activateEntry else { return false }
        activateEntry(); return true
    }
}
@MainActor final class OneDriveSelection {
    let browser: OneDriveBrowser
    let items: [OneDriveItem]
    let generation: UUID
    var parentID: String?
    init(browser: OneDriveBrowser, items: [OneDriveItem], generation: UUID) {
        self.browser = browser; self.items = items; self.generation = generation
        self.parentID = browser.currentParentID
    }
}

/// Embedded in a commander pane; remote items never become local FileEntry paths.
@MainActor final class OneDriveBrowser: UIViewController, UITableViewDataSource, UITableViewDelegate, UIDocumentPickerDelegate {
    let tableView = UITableView(frame: .zero, style: .plain)
    private let treeView = UITableView(frame: .zero, style: .plain)
    private var refreshControl: UIRefreshControl?
    private let pathLabel = UILabel()
    private let countLabel = UILabel()
    private let loadingIndicator = UIActivityIndicatorView(style: .medium)
    private let remoteProfile: RemoteConnection?
    private var locationTitle: String { remoteProfile?.name ?? "OneDrive online" }
    private func onlineLocation(_ name: String? = nil) -> String {
        locationTitle + ":/" + (folders.map(\.name) + (name.map { [$0] } ?? [])).joined(separator: "/")
    }
    private func destinationLocation(_ parent: String?, name: String) async throws -> String {
        guard let client else { return locationTitle + ":/" + name }
        var components = [name], cursor = parent, seen = Set<String>()
        while let id = cursor {
            guard seen.insert(id).inserted, seen.count <= 100 else { throw OneDriveFailure.message("Invalid OneDrive folder hierarchy.") }
            let item = try await client.metadata(id)
            if item.root != nil { break }
            components.insert(item.name, at: 0)
            cursor = item.parentReference?.id
        }
        return locationTitle + ":/" + components.joined(separator: "/")
    }
    private func record(_ action: String, source: String, destination: String) {
        commander?.operationHistory.append(.cloud(record: CloudOperationRecord(action: action, source: source, destination: destination)))
    }
    private let filterField = UITextField()
    private var visibleItems: [OneDriveItem] = []
    private var treeRows: [[OneDriveItem]] = [[]]
    private var treeChildren: [String: [OneDriveItem]] = [:]
    private var expanded: Set<String> = ["root"]
    private var backHistory: [[OneDriveItem]] = []
    private var forwardHistory: [[OneDriveItem]] = []
    private var selectedIDs = Set<String>()
    private var generation = UUID()
    static var clipboard: (selection: OneDriveSelection, move: Bool)?
    weak var commander: ViewController?
    private var previewURLs: [URL] = []
    private enum OnlineUndo {
        case rename(OneDriveItem, String)
        case move(OneDriveItem, String?, String)
    }
    private var undoHistory: [OnlineUndo] = []
    private enum ConflictChoice { case keepBoth, skip, cancel }
    private var conflictPrompt: (UIAlertController, CheckedContinuation<ConflictChoice, Never>)?
    private func finishConflict(_ choice: ConflictChoice) {
        guard let (alert, continuation) = conflictPrompt else { return }
        conflictPrompt = nil
        alert.dismiss(animated: false) { continuation.resume(returning: choice) }
    }
    private func destinationName(_ name: String, folder: Bool, parent: String?, excluding: String? = nil) async throws -> String? {
        guard let client else { throw CancellationError() }
        let names = try await client.children(of: parent).filter { $0.id != excluding }.map(\.name)
        let alternative = OneDriveConflictNames.available(name, folder: folder, existing: names)
        guard alternative != name else { return name }
        let choice: ConflictChoice = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, self.view.window != nil else { continuation.resume(returning: .cancel); return }
                let alert = UIAlertController(title: self.text("Name bereits vorhanden", "Name already exists"),
                    message: self.text("‚\(name)‘ ist im Zielordner bereits vorhanden. Beide behalten erstellt ‚\(alternative)‘. Vorhandene Dateien bleiben unverändert; Ordner werden nicht zusammengeführt.",
                        "‘\(name)’ already exists in the destination. Keep Both creates ‘\(alternative)’. Existing files remain unchanged; folders are not merged."), preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: self.text("Beide behalten", "Keep Both"), style: .default) { [weak self] _ in self?.finishConflict(.keepBoth) })
                alert.addAction(UIAlertAction(title: self.text("Überspringen", "Skip"), style: .default) { [weak self] _ in self?.finishConflict(.skip) })
                alert.addAction(UIAlertAction(title: L10n.get("cancel"), style: .cancel) { [weak self] _ in self?.finishConflict(.cancel) })
                self.conflictPrompt = (alert, continuation)
                self.present(alert, animated: true)
            }
        }, onCancel: { [weak self] in Task { @MainActor in self?.finishConflict(.cancel) } })
        try Task.checkCancellation()
        switch choice { case .keepBoth: return alternative; case .skip: return nil; case .cancel: throw CancellationError() }
    }
    func undoOnlineOperation() {
        guard let record = undoHistory.last, !busy else {
            commander?.updateGlobalStatus(L10n.get("undo_empty")); return
        }
        run(transfer: true) { [weak self] in
            guard let self, let client = self.client else { return }
            switch record {
            case .rename(let item, let name):
                guard item.eTag != nil else { throw OneDriveFailure.message("Cannot safely undo without a OneDrive version.") }
                try await client.rename(item, to: name)
                self.record(L10n.get("undo"), source: self.onlineLocation(item.name), destination: self.onlineLocation(name))
            case .move(let item, let parent, let oldName):
                guard item.eTag != nil else { throw OneDriveFailure.message("Cannot safely undo without a OneDrive version.") }
                let current = try await client.metadata(item.id)
                let source = try await self.destinationLocation(current.parentReference?.id, name: item.name)
                let destination = try await self.destinationLocation(parent, name: oldName)
                try await client.move(item, parent: parent, name: oldName)
                self.record(L10n.get("undo"), source: source, destination: destination)
            }
            self.undoHistory.removeLast()
            self.treeChildren = [:]
            try await self.load()
        }
    }
    private var sortField = 0
    private var ascending = true
    private let backButton = UIButton(type: .system)
    private let forwardButton = UIButton(type: .system)
    private let upButton = UIButton(type: .system)
    private let actionButton = UIButton(type: .system)
    private var palette: ViewController.ThemeColors { ViewController.ThemeColors(darkMode: traitCollection.userInterfaceStyle == .dark) }
    private func key(_ path: [OneDriveItem]) -> String { path.last?.id ?? "root" }
    var hasSelection: Bool { !selectedIDs.isEmpty && !busy }
    var hasSelectedArchives: Bool { selectedItems.contains { !$0.isFolder && ($0.name as NSString).pathExtension.lowercased() == "zip" } }
    var currentParentID: String? { folders.last?.id }
    private var selectedItems: [OneDriveItem] { visibleItems.filter { selectedIDs.contains($0.id) } }
    var selection: OneDriveSelection { OneDriveSelection(browser: self, items: selectedItems, generation: generation) }
    func commanderTool(_ mode: CommanderToolsController.Mode, left: OneDriveBrowser?, right: OneDriveBrowser?, leftURL: URL, rightURL: URL) -> CommanderToolsController? {
        guard !busy, left?.busy != true, right?.busy != true, let client, mode != .rename || !selectedItems.isEmpty else { return nil }
        let initialFolders = folders, selected = selectedItems
        let base = remoteProfile?.root ?? "/"
        let path = (base == "/" ? "" : base) + "/" + folders.map(\.name).joined(separator: "/")
        let hidden = UserDefaults.standard.bool(forKey: "show_hidden_files")
        let controller = CommanderToolsController(mode: mode, root: URL(fileURLWithPath: path), other: rightURL, selected: [], hidden: hidden)
        controller.displayRoot = mode == .compare ? (left?.onlineLocation() ?? leftURL.path) : onlineLocation()
        controller.displayOther = right?.onlineLocation() ?? rightURL.path
        var renamePlan: [CommanderOnlineTools.Rename] = []
        var results: [String: CommanderOnlineTools.Entry] = [:]
        controller.onlineRun = { [weak self, weak controller] query, matchCase, searchPath, fields in
            guard let self else { throw CancellationError() }
            self.busy = true; self.updateNavigation()
            defer { self.busy = false; self.updateNavigation() }
            switch mode {
            case .search:
                guard base == "/" || searchPath == base || searchPath.hasPrefix(base + "/") else { throw RemoteConnection.failure("remote_invalid") }
                let relative = base == "/" ? searchPath : String(searchPath.dropFirst(base.count))
                let parents = try await CommanderOnlineTools.resolve(relative.isEmpty ? "/" : relative, client: client)
                let entries = try await CommanderOnlineTools.scan(client, ancestors: parents, hidden: hidden) { count in
                    controller?.report("\(count) " + self.text("Einträge geprüft …", "entries checked …"))
                }
                results = [:]
                return try entries.filter { try CommanderOnlineTools.matches($0.item.name, query: query, caseSensitive: matchCase) }.map { entry in
                    let url = URL(string: "opencommander-online://result/" + UUID().uuidString)!
                    results[url.absoluteString] = entry
                    let fullPath = (base == "/" ? "" : base) + "/" + (entry.ancestors.map(\.name) + [entry.item.name]).joined(separator: "/")
                    return .init(title: entry.item.name, detail: self.locationTitle + ":" + fullPath, url: url)
                }
            case .compare:
                @MainActor func content(_ browser: OneDriveBrowser?, _ local: URL) async throws -> [String: String] {
                    if let browser, let service = browser.client {
                        return try await CommanderOnlineTools.content(service, ancestors: browser.folders, hidden: hidden) { done, total in
                            controller?.report(browser.locationTitle + ": \(done)/\(total)")
                        }
                    }
                    var snapshot = try await RemoteContent.snapshotAsync(local, hidden: hidden); snapshot.removeValue(forKey: "")
                    return snapshot
                }
                let a = try await content(left, leftURL), b = try await content(right, rightURL)
                return Set(a.keys).union(b.keys).sorted().compactMap { path in
                    if a[path] == "directory" && b[path] == "directory" { return nil }
                    let label = a[path] == nil ? self.text("Nur rechts", "Right only") : b[path] == nil ? self.text("Nur links", "Left only") : a[path] == b[path] ? self.text("Gleich", "Equal") : self.text("Unterschiedlich", "Different")
                    return .init(title: label + " · " + path, detail: "", url: nil)
                }
            case .rename:
                renamePlan = try await CommanderOnlineTools.renamePlan(client, parent: initialFolders.last?.id, selected: selected, fields: fields)
                return renamePlan.map { .init(title: $0.item.name + " → " + $0.name, detail: self.onlineLocation(), url: nil) }
            }
        }
        if mode == .rename {
            controller.onlineApply = { [weak self] in
                guard let self else { throw CancellationError() }
                let plan = renamePlan; renamePlan = []
                self.busy = true; self.updateNavigation()
                defer {
                    self.busy = false; self.treeChildren = [:]; self.updateNavigation()
                    Task { try? await self.load() }
                }
                return try await CommanderOnlineTools.rename(client, plan: plan) { row in
                    self.record(L10n.get("rename"), source: self.onlineLocation(row.item.name), destination: self.onlineLocation(row.name))
                    if let renamed = try? await client.metadata(row.item.id) { self.undoHistory.append(.rename(renamed, row.item.name)) }
                }
            }
        }
        controller.onOpen = { [weak self] url in
            guard let self, let entry = results[url.absoluteString] else { return }
            self.navigate(entry.item.isFolder ? entry.ancestors + [entry.item] : entry.ancestors)
        }
        return controller
    }
    func selectAllOnline() { selectedIDs = Set(visibleItems.map(\.id)); tableView.reloadData(); updateNavigation(); onStateChanged?() }
    func renameOnlineSelection() { if let item = selectedItems.first, selectedItems.count == 1, !busy { namePrompt(item: item) } }
    func deleteOnlineSelection() {
        let selected = selectedItems
        guard !selected.isEmpty, !busy else { return }
        let deleteTitle = remoteProfile == nil ? L10n.get("move_to_trash") : L10n.get("remote_delete")
        let alert = UIAlertController(title: deleteTitle, message: selected.map(\.name).joined(separator: "\n"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: deleteTitle, style: .destructive) { [weak self] _ in
            self?.run(transfer: true) { [weak self] in
                guard let self, let client = self.client else { return }
                for item in selected {
                    try Task.checkCancellation(); try await client.recycle(item)
                    self.record(deleteTitle, source: self.onlineLocation(item.name), destination: self.remoteProfile == nil ? "OneDrive Papierkorb / Recycle bin" : L10n.get("remote_deleted"))
                }
                try await self.load()
            }
        })
        alert.addAction(UIAlertAction(title: L10n.get("cancel"), style: .cancel))
        present(alert, animated: true)
    }
    func previewOnlineSelection(open: Bool = false) { if let item = selectedItems.first { openOnline(item, externally: open) } }
    func zipOnlineSelection() {
        let selected = selectedItems, parent = folders.last?.id
        guard !selected.isEmpty, !busy else { return }
        run(transfer: true) { [weak self] in
            guard let self, let client = self.client else { return }
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent("OpenCommanderOnlineZIP-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            var sources: [URL] = []
            for item in selected {
                let downloaded = try await client.downloadTree(item)
                defer { try? FileManager.default.removeItem(at: downloaded.deletingLastPathComponent()) }
                let source = staging.appendingPathComponent(item.name)
                try FileManager.default.copyItem(at: downloaded, to: source)
                sources.append(source)
            }
            let existing = Set(try await client.children(of: parent).map { $0.name.lowercased() })
            let stem = selected.count == 1 ? (selected[0].isFolder ? selected[0].name : (selected[0].name as NSString).deletingPathExtension) : "Archive"
            var name = stem + ".zip", index = 2
            while existing.contains(name.lowercased()) || sources.contains(where: { $0.lastPathComponent.lowercased() == name.lowercased() }) {
                name = stem + " \(index).zip"; index += 1
            }
            let destination = staging.appendingPathComponent(name)
            let worker = Task.detached(priority: .userInitiated) {
                try Self.createOnlineArchive(sources: sources, destination: destination)
            }
            try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            try Task.checkCancellation()
            try await client.upload(destination, parent: parent)
            self.record(L10n.get("zip"), source: selected.map { self.onlineLocation($0.name) }.joined(separator: ", "), destination: self.onlineLocation(name))
            try await self.load()
        }
    }
    func extractOnlineSelection() {
        let selected = selectedItems.filter { !$0.isFolder && ($0.name as NSString).pathExtension.lowercased() == "zip" }, parent = folders.last?.id
        guard !selected.isEmpty, !busy else { return }
        run(transfer: true) { [weak self] in
            guard let self, let client = self.client else { return }
            var names = Set(try await client.children(of: parent).map { $0.name.lowercased() })
            for item in selected {
                let downloaded = try await client.download(item)
                defer { try? FileManager.default.removeItem(at: downloaded.deletingLastPathComponent()) }
                let stem = (item.name as NSString).deletingPathExtension
                var name = stem, index = 2
                while names.contains(name.lowercased()) { name = stem + " \(index)"; index += 1 }
                names.insert(name.lowercased())
                let destination = downloaded.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
                let worker = Task.detached(priority: .userInitiated) { try Self.extractOnlineArchive(downloaded, to: destination) }
                try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                try await client.uploadTree(destination, parent: parent)
                self.record(L10n.get("extract_archive"), source: self.onlineLocation(item.name), destination: self.onlineLocation(name))
            }
            try await self.load()
        }
    }
    nonisolated private static func extractOnlineArchive(_ source: URL, to directory: URL) throws {
        guard let archive = Archive(url: source, accessMode: .read) else { throw CocoaError(.fileReadCorruptFile) }
        var limits = SafeArchiveLimits()
        for entry in archive { try limits.include(path: entry.path, size: entry.uncompressedSize, symbolicLink: entry.type == .symlink) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        for entry in archive {
            try Task.checkCancellation()
            let destination = directory.appendingPathComponent(entry.path)
            guard destination.standardizedFileURL.path.hasPrefix(directory.path + "/") else { throw CocoaError(.fileReadCorruptFile) }
            if entry.type == .directory {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            } else {
                guard !SafeFileOperations.exists(destination) else { throw SafeFileOperations.conflict(destination) }
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
                let output = try FileHandle(forWritingTo: destination)
                defer { try? output.close() }
                var written: UInt64 = 0
                let checksum = try archive.extract(entry) { data in
                    try Task.checkCancellation()
                    guard UInt64(data.count) <= entry.uncompressedSize - written else { throw CocoaError(.fileReadCorruptFile) }
                    written += UInt64(data.count); try output.write(contentsOf: data)
                }
                guard written == entry.uncompressedSize, checksum == entry.checksum else { throw CocoaError(.fileReadCorruptFile) }
            }
        }
    }
    nonisolated private static func createOnlineArchive(sources: [URL], destination: URL) throws {
        var pending = sources.map { (path: $0.lastPathComponent, url: $0) }
        var entries: [(path: String, url: URL)] = []
        var limits = SafeArchiveLimits()
        while let entry = pending.popLast() {
            try Task.checkCancellation()
            let values = try entry.url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            try limits.include(path: entry.path, size: UInt64(max(0, values.isDirectory == true ? 0 : (values.fileSize ?? 0))), symbolicLink: values.isSymbolicLink == true)
            entries.append(entry)
            if values.isDirectory == true {
                for child in try FileManager.default.contentsOfDirectory(at: entry.url, includingPropertiesForKeys: nil) {
                    pending.append((entry.path + "/" + child.lastPathComponent, child))
                }
            }
        }
        let archive = try Archive(url: destination, accessMode: .create, pathEncoding: nil)
        for entry in entries {
            try Task.checkCancellation()
            try archive.addEntry(with: entry.path, fileURL: entry.url, compressionMethod: .deflate)
        }
    }
    func infoOnlineSelection() {
        guard let selected = selectedItems.first else { return }
        run { [weak self] in
            guard let self, let item = try await self.client?.metadata(selected.id) else { return }
            let size = item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
            let message = String(format: L10n.get("file_info_message"), item.name,
                L10n.get(item.isFolder ? "folder" : "file"),
                self.onlineLocation(item.name),
                size, "—", item.lastModifiedDateTime ?? "—", self.remoteProfile?.scheme.uppercased() ?? self.text("Durch OneDrive verwaltet", "Managed by OneDrive"))
            self.commander?.showScrollableDialog(title: L10n.get("file_info"), message: message)
        }
    }
    func duplicateOnlineSelection() {
        let selected = selectedItems, parent = folders.last?.id
        guard !selected.isEmpty else { return }
        run(transfer: true) { [weak self] in
            guard let self, let client = self.client else { return }
            var names = Set(try await client.children(of: parent).map { $0.name.lowercased() })
            for item in selected {
                let url = try await client.downloadTree(item)
                defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                let suffix = item.isFolder ? "" : (item.name as NSString).pathExtension
                let stem = suffix.isEmpty ? item.name : (item.name as NSString).deletingPathExtension
                var name = "", index = 1
                repeat {
                    name = stem + self.text(" Kopie", " copy") + (index == 1 ? "" : " \(index)") + (suffix.isEmpty ? "" : "." + suffix)
                    index += 1
                } while names.contains(name.lowercased())
                names.insert(name.lowercased())
                let renamed = url.deletingLastPathComponent().appendingPathComponent(name)
                try FileManager.default.moveItem(at: url, to: renamed)
                try await client.uploadTree(renamed, parent: parent)
                self.record(L10n.get("duplicate"), source: self.onlineLocation(item.name), destination: self.onlineLocation(name))
            }
            try await self.load()
        }
    }
    func openOnlineSelection() {
        if let item = selectedItems.first { if item.isFolder { navigate(folders + [item]) } else { openOnline(item, externally: true) } }
    }
    private func openOnline(_ item: OneDriveItem, externally: Bool) {
        guard !item.isFolder else { return }
        run { [weak self] in
            guard let self, let client = self.client else { return }
            let url = try await client.download(item)
            self.previewURLs.append(url)
            let entry = FileEntry(url: url, parent: nil)
            if externally { self.commander?.openDesktopEntry(entry) } else { self.commander?.previewFile(entry) }
        }
    }
    func copyOnlineSelection(move: Bool) {
        guard hasSelection else { return }
        Self.clipboard = (selection, move)
        // A private marker prevents a later unrelated system clipboard from
        // accidentally triggering a stale remote move.
        UIPasteboard.general.setItems([["com.opencommander.onedrive-selection": Data(generation.uuidString.utf8)]], options: [.localOnly: true])
        commander?.updateGlobalStatus(String(format: L10n.get(move ? "clipboard_cut" : "clipboard_copied"), selectedItems.count))
    }
    static var currentClipboard: (selection: OneDriveSelection, move: Bool)? {
        guard UIPasteboard.general.contains(pasteboardTypes: ["com.opencommander.onedrive-selection"]) else { clipboard = nil; return nil }
        return clipboard
    }
    private var client: (any CommanderOnlineClient)?
    var paneTitle = "1"
    var onClose: (() -> Void)?
    var onActivate: (() -> Void)?
    var onStateChanged: (() -> Void)?
    func cancelPendingWork() { work?.cancel(); generation = UUID() }
    func refreshOnline() { reload() }
    func createOnlineFolder() { guard !busy, authenticated else { return }; namePrompt(item: nil) }
    func showOnlineActions() { actions() }
    func navigateOnlineParent() {
        guard !busy, !folders.isEmpty else { return }
        navigate(Array(folders.dropLast()))
    }
    func navigateOnlineBack() { if let path = backHistory.last { navigate(path, history: -1) } }
    func navigateOnlineForward() { if let path = forwardHistory.last { navigate(path, history: 1) } }
    private var items: [OneDriveItem] = []
    private var folders: [OneDriveItem] = []
    private var work: Task<Void, Never>?
    private var busy = false
    private var authenticated = false
    private var exportedURL: URL?
    private let message = UILabel()
    private let clientIDKey = "OneDriveApplicationClientID"
    private var german: Bool { (UserDefaults.standard.string(forKey: "language") ?? Locale.current.language.languageCode?.identifier ?? "en").hasPrefix("de") }
    private func text(_ de: String, _ en: String) -> String { german ? de : en }
    init(remote: RemoteConnection? = nil) { remoteProfile = remote; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = locationTitle
        isModalInPresentation = true
        buildCommanderLayout()
        tableView.accessibilityIdentifier = "OneDriveOnlineFiles"
        message.numberOfLines = 0; message.textAlignment = .center
        message.textColor = .secondaryLabel
        message.accessibilityIdentifier = "OneDriveOnlineStatus"
        tableView.backgroundView = message
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: text("Schließen", "Close"), style: .done, target: self, action: #selector(close))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: text("Aktionen", "Actions"), style: .plain, target: self, action: #selector(actions))
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(reload), for: .valueChanged)
        tableView.refreshControl = refreshControl
        for list in [tableView, treeView] { list.dragDelegate = self; list.dropDelegate = self; list.dragInteractionEnabled = true }
        if let remoteProfile {
            client = RemoteFileClient(remoteProfile)
            reload(); return
        }
        let id = UserDefaults.standard.string(forKey: clientIDKey) ?? Bundle.main.object(forInfoDictionaryKey: "OneDriveClientID") as? String ?? ""
        if OneDriveClient.validClientID(id) {
            client = OneDriveClient(clientID: id)
            do {
                if try client?.hasSavedLogin() == true { reload() }
                else { message.text = text("OpenCommander ist für OneDrive eingerichtet.\n\nÖffne Aktionen → Mit Microsoft verbinden, um dein Konto anzumelden. Es wird kein synchronisierter Ordner benötigt.",
                    "OpenCommander is configured for OneDrive.\n\nChoose Actions → Connect to Microsoft to sign in. No synchronized folder is required.") }
            } catch { message.text = error.localizedDescription }
        } else {
            message.text = text("Direkter Online-Zugang ohne synchronisierten Ordner.\n\nNoch nicht verbunden. Öffne Aktionen → Microsoft-App einrichten. Die Anmeldung im Browser allein verbindet OpenCommander nicht.",
                "Direct online access without a synchronized folder.\n\nNot connected. Choose Actions → Configure Microsoft app. Signing in on the website alone does not connect OpenCommander.")
        }
    }
    private func buildCommanderLayout() {
        let theme = palette
        view.backgroundColor = theme.panelBackground
        let shell = UIStackView()
        shell.axis = .vertical; shell.spacing = 8
        let accent = UIColor(hex: paneTitle == "1" ? "#185bb5" : "#147454")
        let accentLine = UIView(); accentLine.backgroundColor = accent
        accentLine.heightAnchor.constraint(equalToConstant: 3).isActive = true
        shell.addArrangedSubview(accentLine)
        shell.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(shell)
        NSLayoutConstraint.activate([
            shell.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            shell.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            shell.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            shell.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4)
        ])
        let pathRow = UIStackView(); pathRow.spacing = 6; pathRow.alignment = .center
        for (button, symbol, label, action) in [(backButton, "chevron.left", L10n.get("back"), { [weak self] in self?.navigateOnlineBack() }),
            (forwardButton, "chevron.right", L10n.get("forward"), { [weak self] in self?.navigateOnlineForward() }),
            (upButton, "arrow.up", text("Übergeordneter Ordner", "Parent folder"), { [weak self] in self?.navigateOnlineParent() })] {
            button.setImage(UIImage(systemName: symbol), for: .normal)
            button.accessibilityLabel = label
            button.addAction(UIAction { _ in action() }, for: .touchUpInside)
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
            pathRow.addArrangedSubview(button)
        }
        pathLabel.font = .systemFont(ofSize: 11); pathLabel.textColor = theme.secondaryText
        pathLabel.backgroundColor = theme.pathBackground; pathLabel.layer.cornerRadius = 8
        pathLabel.layer.borderWidth = 1; pathLabel.layer.borderColor = theme.pathBorder.cgColor
        pathLabel.lineBreakMode = .byTruncatingMiddle; pathLabel.accessibilityIdentifier = "OneDriveOnlinePath"
        pathLabel.heightAnchor.constraint(equalToConstant: 44).isActive = true
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathRow.addArrangedSubview(pathLabel)
        countLabel.font = .systemFont(ofSize: 11); countLabel.textColor = theme.secondaryText
        pathRow.addArrangedSubview(countLabel)
        loadingIndicator.accessibilityIdentifier = "OneDriveLoading"
        loadingIndicator.accessibilityLabel = L10n.get("directory_loading")
        pathRow.addArrangedSubview(loadingIndicator)
        actionButton.setTitle(text("Aktionen", "Actions"), for: .normal)
        actionButton.titleLabel?.font = .systemFont(ofSize: 11)
        actionButton.addTarget(self, action: #selector(actions), for: .touchUpInside)
        pathRow.addArrangedSubview(actionButton)
        let closeButton = UIButton(type: .system); closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.accessibilityLabel = text("Zurück zum lokalen Ordner", "Return to local folder")
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        closeButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        pathRow.addArrangedSubview(closeButton); shell.addArrangedSubview(pathRow)
        let columns = UIStackView(); columns.axis = .horizontal; columns.spacing = 6
        func column(_ title: String) -> UIStackView {
            let stack = UIStackView(); stack.axis = .vertical
            stack.backgroundColor = theme.columnBackground; stack.layer.cornerRadius = 10
            stack.layer.borderWidth = 1; stack.layer.borderColor = theme.columnBorder.cgColor; stack.clipsToBounds = true
            let header = UILabel(); header.text = "  " + title; header.font = .boldSystemFont(ofSize: 12)
            header.backgroundColor = theme.columnHeaderBackground; header.textColor = accent
            header.heightAnchor.constraint(equalToConstant: 32).isActive = true
            stack.addArrangedSubview(header); return stack
        }
        let treeColumn = column(L10n.get("tree")), fileColumn = column(L10n.get("files"))
        treeView.dataSource = self; treeView.delegate = self; treeView.rowHeight = 44
        treeView.backgroundColor = theme.treeBackground; treeView.separatorColor = theme.columnBorder
        treeView.accessibilityIdentifier = "OneDriveOnlineTree"; treeColumn.addArrangedSubview(treeView)
        filterField.placeholder = L10n.get("filter_names"); filterField.borderStyle = .roundedRect
        filterField.clearButtonMode = .always; filterField.font = .systemFont(ofSize: 12)
        filterField.accessibilityIdentifier = "OneDriveOnlineFilter"
        filterField.addAction(UIAction { [weak self] _ in self?.onActivate?(); self?.applyListingOrder() }, for: .editingChanged)
        fileColumn.addArrangedSubview(filterField)
        let sortRow = UIStackView()
        for (index, name) in ["sort_name", "sort_size", "sort_type", "sort_date"].enumerated() {
            let button = UIButton(type: .system); button.setTitle(L10n.get(name), for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 11)
            if index > 0 { button.widthAnchor.constraint(equalToConstant: [0,90,70,125][index]).isActive = true }
            button.addAction(UIAction { [weak self] _ in
                guard let self else { return }; self.ascending = self.sortField == index ? !self.ascending : true
                self.onActivate?()
                self.sortField = index; self.applyListingOrder()
            }, for: .touchUpInside)
            sortRow.addArrangedSubview(button)
        }
        fileColumn.addArrangedSubview(sortRow)
        tableView.dataSource = self; tableView.delegate = self; tableView.rowHeight = 44
        tableView.backgroundColor = theme.fileBackground; tableView.separatorColor = theme.columnBorder
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(openDoubleTappedItem)); doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = true; doubleTap.delaysTouchesEnded = false; tableView.addGestureRecognizer(doubleTap)
        fileColumn.addArrangedSubview(tableView)
        columns.addArrangedSubview(treeColumn); columns.addArrangedSubview(fileColumn)
        treeColumn.widthAnchor.constraint(equalTo: columns.widthAnchor, multiplier: 0.28).isActive = true
        shell.addArrangedSubview(columns)
        updateNavigation()
    }
    private func updateNavigation() {
        pathLabel.text = "  " + onlineLocation()
        backButton.isEnabled = !busy && !backHistory.isEmpty
        forwardButton.isEnabled = !busy && !forwardHistory.isEmpty
        upButton.isEnabled = !busy && !folders.isEmpty
        countLabel.text = busy ? L10n.get("directory_loading") : "\(selectedIDs.count)/\(visibleItems.count)"
        if busy { loadingIndicator.startAnimating() } else { loadingIndicator.stopAnimating() }
    }
    private func applyListingOrder() {
        let filter = filterField.text ?? ""
        visibleItems = items.filter { filter.isEmpty || $0.name.localizedStandardContains(filter) }.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            let comparison: ComparisonResult
            switch sortField {
            case 1: comparison = (a.size ?? 0) == (b.size ?? 0) ? a.name.localizedStandardCompare(b.name) : (a.size ?? 0) < (b.size ?? 0) ? .orderedAscending : .orderedDescending
            case 2: comparison = (a.name as NSString).pathExtension.localizedStandardCompare((b.name as NSString).pathExtension)
            case 3: comparison = (a.lastModifiedDateTime ?? "").compare(b.lastModifiedDateTime ?? "")
            default: comparison = a.name.localizedStandardCompare(b.name)
            }
            let order = comparison == .orderedSame ? a.name.localizedStandardCompare(b.name) : comparison
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
        selectedIDs.formIntersection(Set(visibleItems.map(\.id)))
        if authenticated {
            message.text = visibleItems.isEmpty ? (items.isEmpty ? text("Dieser Ordner ist leer.", "This folder is empty.") : text("Keine passenden Dateien.", "No matching files.")) : nil
        }
        tableView.reloadData(); updateNavigation(); onStateChanged?()
    }
    private func rebuildTree() {
        treeRows = []; var visited = Set<String>()
        func append(_ path: [OneDriveItem]) {
            guard visited.insert(key(path)).inserted else { return }
            treeRows.append(path)
            if expanded.contains(key(path)) {
                for item in (treeChildren[key(path)] ?? []).filter({ $0.isFolder }) { append(path + [item]) }
            }
        }
        append([]); treeView.reloadData()
    }
    private func resetAccountView() {
        authenticated = false; items = []; folders = []; visibleItems = []
        selectedIDs = []; generation = UUID(); treeChildren = [:]; expanded = ["root"]; undoHistory = []
        if Self.clipboard?.selection.browser === self { Self.clipboard = nil }
        backHistory = []; forwardHistory = []
        applyListingOrder(); rebuildTree()
    }
    private func navigate(_ path: [OneDriveItem], history: Int = 0) {
        guard !busy, authenticated else { return }
        onActivate?()
        run { [weak self] in
            guard let self else { return }; let old = self.folders
            try await self.load(path: path)
            if history == -1 { self.backHistory.removeLast(); self.forwardHistory.append(old) }
            else if history == 1 { self.forwardHistory.removeLast(); self.backHistory.append(old) }
            else if self.key(old) != self.key(path) { self.backHistory.append(old); self.forwardHistory.removeAll() }
        }
    }
    @objc private func openDoubleTappedItem(_ gesture: UITapGestureRecognizer) {
        guard !busy, let row = tableView.indexPathForRow(at: gesture.location(in: tableView)), row.row < visibleItems.count else { return }
        let item = visibleItems[row.row]
        if item.isFolder { navigate(folders + [item]) } else { openOnline(item, externally: true) }
    }
    @objc private func close() {
        work?.cancel()
        if let onClose { onClose() } else { dismiss(animated: true) }
    }
    private var completionNotice: String?
    private func observeTransfer(_ client: (any CommanderOnlineClient)?) {
        (client as? RemoteFileClient)?.transferProgress = { [weak self] phase, done, total in
            guard let self, total > 0 else { return }
            let percent = Int(min(100, Double(done) / Double(total) * 100))
            self.commander?.updateTransferProgress(self.locationTitle + ": " + L10n.get(phase) + " · \(done)/\(total) Bytes (\(percent)%)", progress: percent)
        }
    }
    private func transferProgress(_ completed: Int, total: Int, name: String) {
        let percent = total == 0 ? 0 : completed * 100 / total
        commander?.updateTransferProgress(locationTitle + ": \(completed)/\(total) " + text("Objekte bearbeitet", "items processed") + " (\(percent)%) · " + name, progress: percent)
    }
    private func rememberRecovery(_ client: any CommanderOnlineClient, source: String) {
        guard let backup = client.moveBackupLocation else { return }
        record(L10n.get("remote_recovery"), source: source, destination: backup)
        completionNotice = L10n.get("remote_recovery_notice") + "\n" + backup
    }
    private func run(transfer: Bool = false, _ action: @escaping () async throws -> Void) {
        guard !busy, commander?.operationInProgress != true else { return }
        busy = true; completionNotice = nil
        updateNavigation()
        if transfer {
            observeTransfer(client)
            commander?.showProgress(locationTitle + ": " + text("Übertragung läuft…", "transferring…"), progress: 0, cancellable: true, indeterminate: true, onCancel: { [weak self] in self?.work?.cancel() })
        }
        work = Task { [weak self] in
            guard let self else { return }
            var status = self.locationTitle + ": " + self.text("fertig", "complete")
            defer {
                self.busy = false; self.refreshControl?.endRefreshing(); self.updateNavigation(); self.onStateChanged?()
                if transfer { self.commander?.finishProgress(status); self.commander?.refreshAllPanes(clearSelectionIn: []) }
                if transfer { (self.client as? RemoteFileClient)?.transferProgress = nil }
            }
            do { try await action(); status = self.completionNotice ?? status }
            catch is CancellationError { status = self.text("Abgebrochen; abgeschlossene Schritte bleiben erhalten.", "Cancelled; completed steps are retained.") + (self.completionNotice.map { "\n" + $0 } ?? "") }
            catch {
                let nsError = error as NSError
                let description = nsError.domain == "OpenCommander.Remote" ? L10n.get(nsError.localizedDescription) : error.localizedDescription
                status = description + (self.completionNotice.map { "\n" + $0 } ?? ""); self.error(status)
            }
        }
    }
    private func error(_ description: String) {
        message.text = items.isEmpty ? description : nil
        guard presentedViewController == nil, view.window != nil else { return }
        let alert = UIAlertController(title: locationTitle, message: description, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
    private func load(path: [OneDriveItem]? = nil) async throws {
        guard let client else { return }
        let requested = path ?? folders
        let listing = try await client.children(of: requested.last?.id)
        var cache = treeChildren
        // Mutation invalidation must not leave a nested location with only
        // an empty root row. Rebuild its ancestor listings, not the whole drive.
        for count in 0..<requested.count {
            let ancestor = Array(requested.prefix(count))
            if cache[key(ancestor)] == nil { cache[key(ancestor)] = try await client.children(of: ancestor.last?.id) }
        }
        try Task.checkCancellation()
        items = listing
        folders = requested; selectedIDs = []
        cache[key(folders)] = listing; treeChildren = cache
        for count in 0...folders.count { expanded.insert(key(Array(folders.prefix(count)))) }
        authenticated = true
        title = folders.last?.name ?? locationTitle
        message.text = items.isEmpty ? text("Dieser Ordner ist leer.", "This folder is empty.") : nil
        applyListingOrder(); rebuildTree()
    }
    @objc private func reload() {
        guard client != nil else { refreshControl?.endRefreshing(); return }
        run { [weak self] in try await self?.load() }
    }
    @objc private func actions() {
        onActivate?()
        guard !busy else { return }
        let menu = UIAlertController(title: locationTitle, message: text("Dateien und Ordner direkt in OpenCommander. Vorschau, Kopieren, Verschieben und Drag-and-drop verwenden die normalen Bedienelemente.", "Files and folders directly in OpenCommander. Preview, copy, move and drag-and-drop use the regular controls."), preferredStyle: .actionSheet)
        if remoteProfile == nil {
        menu.addAction(UIAlertAction(title: text("Mit Microsoft verbinden", "Connect to Microsoft"), style: .default) { [weak self] _ in self?.connect() })
        menu.addAction(UIAlertAction(title: text("Microsoft-App einrichten", "Configure Microsoft app"), style: .default) { [weak self] _ in self?.configure() })
        }
        if client != nil && authenticated {
            if !folders.isEmpty { menu.addAction(UIAlertAction(title: text("Übergeordneter Ordner", "Parent folder"), style: .default) { [weak self] _ in
                self?.navigateOnlineParent()
            }) }
            menu.addAction(UIAlertAction(title: text("Aktualisieren", "Refresh"), style: .default) { [weak self] _ in self?.reload() })
            menu.addAction(UIAlertAction(title: text("Neuer Ordner", "New folder"), style: .default) { [weak self] _ in self?.namePrompt(item: nil) })
            menu.addAction(UIAlertAction(title: text("Dateien / Ordner hochladen…", "Upload files / folders…"), style: .default) { [weak self] _ in
                guard let self else { return }
                let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item, .folder], asCopy: false)
                picker.delegate = self; picker.allowsMultipleSelection = true
                self.present(picker, animated: true)
            })
            menu.addAction(UIAlertAction(title: text("Verbindung trennen", "Disconnect"), style: .destructive) { [weak self] _ in
                if self?.remoteProfile != nil { self?.onClose?() } else { self?.disconnect() }
            })
        }
        menu.addAction(UIAlertAction(title: text("Abbrechen", "Cancel"), style: .cancel))
        if let item = selectedItems.first, let row = visibleItems.firstIndex(where: { $0.id == item.id }) {
            menu.addAction(UIAlertAction(title: text("Ausgewählte Datei / Ordner…", "Selected file / folder…"), style: .default) { [weak self] _ in self?.itemActions(item, row: IndexPath(row: row, section: 0)) })
        }
        menu.popoverPresentationController?.sourceView = actionButton
        menu.popoverPresentationController?.sourceRect = actionButton.bounds
        present(menu, animated: true)
    }
    private func configure() {
        let alert = UIAlertController(title: text("Microsoft-App-Registrierung", "Microsoft app registration"),
            message: text("Einmalige Entwickler-Einrichtung:\n\n1. Auf entra.microsoft.com → App-Registrierungen → Neue Registrierung: OpenCommander, auch persönliche Microsoft-Konten zulassen.\n2. Authentifizierung → Öffentliche Clientflows zulassen: Ja.\n3. API-Berechtigungen → Microsoft Graph → Delegiert: Files.ReadWrite.\n4. Application (client) ID hier einfügen. Kein Client-Secret und kein Passwort.\n\nDetails: docs/onedrive-online.md im Repository.",
                "One-time developer setup:\n\n1. entra.microsoft.com → App registrations → New registration: OpenCommander, allow personal Microsoft accounts too.\n2. Authentication → Allow public client flows: Yes.\n3. API permissions → Microsoft Graph → Delegated: Files.ReadWrite.\n4. Paste Application (client) ID below. No client secret or password.\n\nDetails: docs/onedrive-online.md in the repository."), preferredStyle: .alert)
        alert.addTextField { [weak self] field in
            field.placeholder = "Application (client) ID"; field.autocorrectionType = .no
            field.text = self?.client?.clientID
            field.accessibilityIdentifier = "OneDriveClientID"
        }
        alert.addAction(UIAlertAction(title: text("Speichern", "Save"), style: .default) { [weak self] _ in
            guard let self else { return }
            let id = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard OneDriveClient.validClientID(id) else { self.error(self.text("Die Client-ID muss eine gültige UUID sein.", "Client ID must be a valid UUID.")); return }
            self.client = OneDriveClient(clientID: id)
            UserDefaults.standard.set(id, forKey: self.clientIDKey)
            self.resetAccountView()
            self.connect()
        })
        alert.addAction(UIAlertAction(title: text("Anleitung öffnen", "Open instructions"), style: .default) { _ in
            DesktopBridge.shared?.openFile(URL(string: "https://learn.microsoft.com/en-us/entra/identity-platform/quickstart-register-app")!, application: nil) { _, _ in }
        })
        alert.addAction(UIAlertAction(title: text("Abbrechen", "Cancel"), style: .cancel))
        present(alert, animated: true)
    }
    private func connect() {
        guard let client else { configure(); return }
        run { [weak self] in
            guard let self else { return }
            let code = try await client.beginLogin()
            let alert = UIAlertController(title: self.text("Microsoft-Anmeldung", "Microsoft sign-in"),
                message: self.text("Öffne \(code.verification_uri) und gib diesen Code ein:\n\n\(code.user_code)\n\nPrüfe die angefragten Dateiberechtigungen. OpenCommander liest keine Browser-Passwörter.",
                    "Open \(code.verification_uri) and enter this code:\n\n\(code.user_code)\n\nReview the requested file permissions. OpenCommander does not read browser passwords."), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: self.text("Code kopieren und Browser öffnen", "Copy code and open browser"), style: .default) { _ in
                UIPasteboard.general.string = code.user_code
                if let url = URL(string: code.verification_uri), url.scheme == "https", url.host == "microsoft.com" || url.host?.hasSuffix(".microsoft.com") == true {
                    DesktopBridge.shared?.openFile(url, application: nil) { _, _ in }
                }
            })
            alert.addAction(UIAlertAction(title: self.text("Abbrechen", "Cancel"), style: .cancel) { [weak self] _ in self?.work?.cancel() })
            self.present(alert, animated: true)
            self.message.text = self.text("Warte auf Microsoft-Anmeldung…", "Waiting for Microsoft sign-in…")
            do {
                try await client.completeLogin(code)
                if self.presentedViewController === alert { await self.dismissAsync() }
                try await self.load()
            } catch {
                if self.presentedViewController === alert { await self.dismissAsync() }
                throw error
            }
        }
    }
    private func dismissAsync() async {
        await withCheckedContinuation { continuation in dismiss(animated: true) { continuation.resume() } }
    }
    private func disconnect() {
        let alert = UIAlertController(title: text("OneDrive trennen?", "Disconnect OneDrive?"), message: text("Die gespeicherte Anmeldung wird aus dem Schlüsselbund entfernt. Online-Dateien werden nicht gelöscht.", "The saved sign-in is removed from Keychain. Online files are not deleted."), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: text("Trennen", "Disconnect"), style: .destructive) { [weak self] _ in
            guard let self else { return }
            do {
                try self.client?.disconnect(); self.resetAccountView()
                self.message.text = self.text("Verbindung getrennt.", "Disconnected.")
            } catch { self.error(error.localizedDescription) }
        })
        alert.addAction(UIAlertAction(title: text("Abbrechen", "Cancel"), style: .cancel))
        present(alert, animated: true)
    }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { tableView === treeView ? treeRows.count : visibleItems.count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = OneDriveCell(style: .default, reuseIdentifier: nil)
        cell.activateEntry = { [weak self, weak tableView] in
            guard let self, let tableView else { return }
            self.tableView(tableView, didSelectRowAt: indexPath)
        }
        let theme = palette
        if tableView === treeView {
            let path = treeRows[indexPath.row], id = key(path)
            cell.textLabel?.text = String(repeating: "  ", count: path.count) + (expanded.contains(id) ? "▼ " : "▶ ") + (path.last?.name ?? locationTitle)
            cell.textLabel?.font = .systemFont(ofSize: 12); cell.textLabel?.textColor = theme.primaryText
            cell.backgroundColor = id == key(folders) ? theme.selectionBackground : .clear
            cell.accessibilityIdentifier = "OneDriveTree-\(id)"
            return cell
        }
        let item = visibleItems[indexPath.row]
        let row = UIStackView(); row.spacing = 4; row.alignment = .center; row.translatesAutoresizingMaskIntoConstraints = false
        let icon = UIImageView(image: UIImage(systemName: item.isFolder ? "folder.fill" : "doc"))
        icon.tintColor = item.isFolder ? .systemOrange : .systemBlue
        icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
        row.addArrangedSubview(icon)
        for (index, value) in [item.name, item.isFolder ? "DIR" : ByteCountFormatter.string(fromByteCount: item.size ?? 0, countStyle: .file),
            item.isFolder ? "DIR" : (item.name as NSString).pathExtension.uppercased(),
            item.lastModifiedDateTime.map { String($0.prefix(16)).replacingOccurrences(of: "T", with: " ") } ?? "—"].enumerated() {
            let label = UILabel(); label.text = value; label.font = .systemFont(ofSize: index == 0 ? 12 : 10)
            label.textColor = index == 0 ? theme.primaryText : theme.secondaryText
            if index > 0 { label.widthAnchor.constraint(equalToConstant: [0,90,70,125][index]).isActive = true; label.textAlignment = .center }
            else { label.lineBreakMode = .byTruncatingMiddle; label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
            row.addArrangedSubview(label)
        }
        cell.contentView.addSubview(row)
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor), row.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor)])
        cell.backgroundColor = selectedIDs.contains(item.id) ? theme.selectionBackground : theme.fileBackground
        cell.isAccessibilityElement = true; cell.accessibilityLabel = item.name
        cell.accessibilityIdentifier = "OneDriveFile-\(item.id)"
        cell.accessibilityTraits = selectedIDs.contains(item.id) ? [.button, .selected] : [.button]
        return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        commander?.view.endEditing(true)
        tableView.deselectRow(at: indexPath, animated: false)
        onActivate?()
        guard !busy else { return }
        if tableView === treeView {
            let path = treeRows[indexPath.row], id = key(path)
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
            if id == key(folders) { rebuildTree() } else { navigate(path) }
        } else {
            let item = visibleItems[indexPath.row]
            if selectedIDs.contains(item.id) { selectedIDs.remove(item.id) } else { selectedIDs.insert(item.id) }
            tableView.reloadData(); updateNavigation(); onActivate?()
        }
    }
    private func itemActions(_ item: OneDriveItem, row: IndexPath) {
        let alert = UIAlertController(title: item.name, message: nil, preferredStyle: .actionSheet)
        selectedIDs = [item.id]; tableView.reloadData(); updateNavigation(); onActivate?()
        if !item.isFolder {
            alert.addAction(UIAlertAction(title: L10n.get("preview"), style: .default) { [weak self] _ in self?.openOnline(item, externally: false) })
            alert.addAction(UIAlertAction(title: L10n.get("open"), style: .default) { [weak self] _ in self?.openOnline(item, externally: true) })
            alert.addAction(UIAlertAction(title: text("Herunterladen…", "Download…"), style: .default) { [weak self] _ in
                self?.run { [weak self] in
                    guard let self, let client = self.client else { return }
                    self.cleanExport()
                    let url = try await client.download(item)
                    self.exportedURL = url
                    let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
                    picker.delegate = self
                    self.present(picker, animated: true)
                }
            })
        }
        alert.addAction(UIAlertAction(title: L10n.get("copy"), style: .default) { [weak self] _ in self?.copyOnlineSelection(move: false) })
        alert.addAction(UIAlertAction(title: L10n.get("cut"), style: .default) { [weak self] _ in self?.copyOnlineSelection(move: true) })
        alert.addAction(UIAlertAction(title: text("Umbenennen", "Rename"), style: .default) { [weak self] _ in self?.namePrompt(item: item) })
        alert.addAction(UIAlertAction(title: remoteProfile == nil ? text("In OneDrive-Papierkorb verschieben", "Move to OneDrive recycle bin") : L10n.get("remote_delete"), style: .destructive) { [weak self] _ in self?.confirmRecycle(item) })
        alert.addAction(UIAlertAction(title: text("Abbrechen", "Cancel"), style: .cancel))
        alert.popoverPresentationController?.sourceView = tableView
        alert.popoverPresentationController?.sourceRect = tableView.rectForRow(at: row)
        present(alert, animated: true)
    }
    private func namePrompt(item: OneDriveItem?) {
        let alert = UIAlertController(title: item == nil ? text("Neuer Ordner", "New folder") : text("Umbenennen", "Rename"), message: nil, preferredStyle: .alert)
        alert.addTextField { $0.text = item?.name }
        alert.addAction(UIAlertAction(title: text("Speichern", "Save"), style: .default) { [weak self] _ in
            let name = alert.textFields?.first?.text ?? ""
            self?.run { [weak self] in
                guard let self, let client = self.client else { return }
                if let item {
                    try await client.rename(item, to: name)
                    self.record(L10n.get("rename_button"), source: self.onlineLocation(item.name), destination: self.onlineLocation(name))
                    self.undoHistory.append(.rename(try await client.metadata(item.id), item.name))
                }
                else {
                    try await client.createFolder(name, parent: self.folders.last?.id)
                    self.record(L10n.get("folder"), source: self.onlineLocation(), destination: self.onlineLocation(name))
                }
                try await self.load()
            }
        })
        alert.addAction(UIAlertAction(title: text("Abbrechen", "Cancel"), style: .cancel))
        present(alert, animated: true)
    }
    private func confirmRecycle(_ item: OneDriveItem) {
        let alert = UIAlertController(title: remoteProfile == nil ? text("In den Papierkorb verschieben?", "Move to recycle bin?") : L10n.get("remote_delete"), message: item.name, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: text("Verschieben", "Move"), style: .destructive) { [weak self] _ in
            self?.run { [weak self] in
                guard let self, let client = self.client else { return }
                try await client.recycle(item)
                self.record(L10n.get("move_to_trash"), source: self.onlineLocation(item.name), destination: "OneDrive Papierkorb / Recycle bin")
                try await self.load()
            }
        })
        alert.addAction(UIAlertAction(title: text("Abbrechen", "Cancel"), style: .cancel))
        present(alert, animated: true)
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if exportedURL != nil { cleanExport(); return }
        receiveLocal(urls)
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { cleanExport() }
    private func cleanExport() {
        if let exportedURL {
            // Only remove the unique temporary directory created by this download.
            try? FileManager.default.removeItem(at: exportedURL.deletingLastPathComponent())
            self.exportedURL = nil
        }
    }
}

extension OneDriveBrowser: UITableViewDragDelegate, UITableViewDropDelegate {
    /// Complete the destination first. A failed/cancelled operation never
    /// removes its source; an unfinished folder may remain at the destination.
    func receiveLocal(_ urls: [URL], parent: String? = nil, useCurrentFolder: Bool = true, move: Bool = false, completion: @escaping () -> Void = {}) {
        guard !busy, authenticated, !urls.isEmpty, commander?.operationInProgress != true else { completion(); return }
        let destination = useCurrentFolder ? folders.last?.id : parent
        run(transfer: true) { [weak self] in
            defer { completion() }
            guard let self, let client = self.client else { return }
            for (index, url) in urls.enumerated() {
                self.transferProgress(index, total: urls.count, name: url.lastPathComponent)
                try Task.checkCancellation()
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                let folder = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                guard let name = try await self.destinationName(url.lastPathComponent, folder: folder, parent: destination) else { continue }
                let targetLocation = try await self.destinationLocation(destination, name: name)
                let before = try await Task.detached { try OneDriveClient.localSnapshot(url) }.value
                let container = FileManager.default.temporaryDirectory.appendingPathComponent("OpenCommander-OneDrive-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false)
                defer { try? FileManager.default.removeItem(at: container) }
                let staged = container.appendingPathComponent(name)
                try await Task.detached { try FileManager.default.copyItem(at: url, to: staged) }.value
                let preparedSnapshot = try await Task.detached { try OneDriveClient.localSnapshot(url) }.value
                guard preparedSnapshot == before else { throw OneDriveFailure.message("Source changed while preparing transfer. Source retained.") }
                try await client.uploadTree(staged, parent: destination)
                self.record(L10n.get("copy"), source: url.path, destination: targetLocation)
                if move {
                    try Task.checkCancellation()
                    let currentSnapshot = try await Task.detached { try OneDriveClient.localSnapshot(url) }.value
                    guard currentSnapshot == before else { throw OneDriveFailure.message("Source changed during transfer. Both copies retained.") }
                    // Recoverable, unlike removing a user's original outright.
                    var trashed: NSURL?
                    try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
                    self.record(L10n.get("move"), source: url.path, destination: targetLocation)
                }
            }
            try await self.load()
        }
    }
    func receiveOnline(_ selection: OneDriveSelection, parent: String? = nil, useCurrentFolder: Bool = true, move: Bool) {
        let source = selection.browser
        guard !busy, authenticated, selection.generation == source.generation, !selection.items.isEmpty else { return }
        let destination = useCurrentFolder ? folders.last?.id : parent
        run(transfer: true) { [weak self] in
            guard let self, let targetClient = self.client, let sourceClient = source.client else { return }
            self.observeTransfer(sourceClient)
            defer { (sourceClient as? RemoteFileClient)?.transferProgress = nil }
            for (index, item) in selection.items.enumerated() {
                self.transferProgress(index, total: selection.items.count, name: item.name)
                try Task.checkCancellation()
                let sourceLocation = try await source.destinationLocation(selection.parentID, name: item.name)
                // Validate ancestors with metadata, including collapsed/unloaded
                // tree targets. Never copy a folder into itself or descendants.
                let sameConnection = targetClient.clientID == sourceClient.clientID
                if sameConnection { try await targetClient.validateDestination(destination, excluding: item.id) }
                guard let name = try await self.destinationName(item.name, folder: item.isFolder, parent: destination, excluding: move ? item.id : nil) else { continue }
                let targetLocation = try await self.destinationLocation(destination, name: name)
                if move && sameConnection {
                    // Name and parent change atomically; never rename the source first.
                    try await sourceClient.move(item, parent: destination, name: name)
                    self.record(L10n.get("move"), source: sourceLocation, destination: targetLocation)
                    self.undoHistory.append(.move(try await sourceClient.metadata(item.id), selection.parentID, item.name))
                } else {
                    let snapshot = move ? try await sourceClient.remoteSnapshot(item) : [:]
                    let url = try await sourceClient.downloadTree(item)
                    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                    let content = try await Task.detached { try RemoteContent.snapshot(url) }.value
                    if move, sourceClient is RemoteFileClient, content != snapshot { throw RemoteConnection.failure("remote_changed") }
                    let staged = url.deletingLastPathComponent().appendingPathComponent(name)
                    if staged != url { try FileManager.default.moveItem(at: url, to: staged) }
                    try await targetClient.uploadTree(staged, parent: destination)
                    self.record(L10n.get("copy"), source: sourceLocation, destination: targetLocation)
                    if move {
                        // Verify the complete destination before changing the source.
                        guard let uploaded = try await targetClient.children(of: destination).first(where: { $0.name == name }) else { throw RemoteConnection.failure("remote_changed") }
                        let verified = try await targetClient.downloadTree(uploaded)
                        defer { try? FileManager.default.removeItem(at: verified.deletingLastPathComponent()) }
                        guard try await Task.detached(operation: { try RemoteContent.snapshot(verified) }).value == content else { throw RemoteConnection.failure("remote_changed") }
                        do { try await sourceClient.recycleUnchanged(item, snapshot: snapshot) }
                        catch { self.rememberRecovery(sourceClient, source: sourceLocation); throw error }
                        self.record(L10n.get("move"), source: sourceLocation, destination: targetLocation)
                        self.rememberRecovery(sourceClient, source: sourceLocation)
                    }
                }
            }
            if Self.clipboard?.selection === selection, move { Self.clipboard = nil }
            self.treeChildren = [:]; source.treeChildren = [:]
            try await self.load()
            if source !== self { try await source.load() }
        }
    }
    func exportOnline(_ selection: OneDriveSelection, to directory: URL, move: Bool) {
        guard !busy, selection.generation == generation, !selection.items.isEmpty else { return }
        run(transfer: true) { [weak self] in
            guard let self, let client = self.client else { return }
            let scope = directory.startAccessingSecurityScopedResource()
            defer { if scope { directory.stopAccessingSecurityScopedResource() } }
            for (index, item) in selection.items.enumerated() {
                self.transferProgress(index, total: selection.items.count, name: item.name)
                try Task.checkCancellation()
                let sourceLocation = try await self.destinationLocation(selection.parentID, name: item.name)
                let snapshot = move ? try await client.remoteSnapshot(item) : [:]
                let url = try await client.downloadTree(item)
                defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                let content = try await Task.detached { try RemoteContent.snapshot(url) }.value
                if move, client is RemoteFileClient, content != snapshot { throw RemoteConnection.failure("remote_changed") }
                let destination = directory.appendingPathComponent(item.name)
                guard !FileManager.default.fileExists(atPath: destination.path) else { throw OneDriveFailure.message("Destination already exists: " + item.name + ". Source retained.") }
                // Copy into an isolated directory on the destination volume;
                // expose the final name only once the whole tree is available.
                let staging = directory.appendingPathComponent(".OpenCommander-transfer-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
                defer { try? FileManager.default.removeItem(at: staging) }
                let ready = staging.appendingPathComponent(item.name)
                try await Task.detached { try FileManager.default.copyItem(at: url, to: ready) }.value
                guard try await Task.detached(operation: { try RemoteContent.snapshot(ready) }).value == content else { throw RemoteConnection.failure("remote_changed") }
                try Task.checkCancellation()
                try FileManager.default.moveItem(at: ready, to: destination)
                self.record(L10n.get("copy"), source: sourceLocation, destination: destination.path)
                if move {
                    do { try await client.recycleUnchanged(item, snapshot: snapshot) }
                    catch { self.rememberRecovery(client, source: sourceLocation); throw error }
                    self.record(L10n.get("move"), source: sourceLocation, destination: destination.path)
                    self.rememberRecovery(client, source: sourceLocation)
                }
            }
            if Self.clipboard?.selection === selection, move { Self.clipboard = nil }
            self.treeChildren = [:]; try await self.load()
        }
    }
    func receiveProviders(_ providers: [NSItemProvider], parent: String? = nil, useCurrentFolder: Bool = true) {
        guard !busy, authenticated, commander?.operationInProgress != true else { return }
        let target = useCurrentFolder ? folders.last?.id : parent
        let move = commander?.moveMode == true
        let expectedGeneration = generation
        // Prevent navigation changing the destination while provider loading.
        busy = true; updateNavigation()
        FileDropTransfer.load(providers) { [weak self] result in
            guard let self else { return }
            self.busy = false; self.updateNavigation()
            guard self.generation == expectedGeneration else {
                if case .success(let batch) = result { batch.releaseResources() }
                return
            }
            switch result {
            case .failure(let error): self.error(error.localizedDescription)
            case .success(let batch):
                if move && batch.items.contains(where: { !$0.isOriginal }) {
                    batch.releaseResources(); self.error(L10n.get("drop_original_unavailable")); return
                }
                self.receiveLocal(batch.items.map(\.url), parent: target, useCurrentFolder: false, move: move) { batch.releaseResources() }
            }
        }
    }
    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard tableView === self.tableView, visibleItems.indices.contains(indexPath.row), !busy else { return nil }
        let item = visibleItems[indexPath.row]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return UIMenu() }
            self.selectedIDs = [item.id]; self.tableView.reloadData(); self.updateNavigation(); self.onActivate?()
            var actions = [UIAction(title: L10n.get("open"), image: UIImage(systemName: "arrow.up.forward.app")) { [weak self] _ in self?.openOnlineSelection() }]
            if !item.isFolder { actions.append(UIAction(title: L10n.get("preview"), image: UIImage(systemName: "eye")) { [weak self] _ in self?.previewOnlineSelection() }) }
            actions += [UIAction(title: L10n.get("copy")) { [weak self] _ in self?.copyOnlineSelection(move: false) },
                        UIAction(title: L10n.get("cut")) { [weak self] _ in self?.copyOnlineSelection(move: true) },
                        UIAction(title: L10n.get("paste")) { [weak self] _ in self?.commander?.pasteClipboard() },
                        UIAction(title: L10n.get("rename_button")) { [weak self] _ in self?.renameOnlineSelection() },
                        UIAction(title: L10n.get("duplicate")) { [weak self] _ in self?.duplicateOnlineSelection() },
                        UIAction(title: L10n.get("file_info")) { [weak self] _ in self?.infoOnlineSelection() },
                        UIAction(title: L10n.get("move_to_trash"), attributes: .destructive) { [weak self] _ in self?.deleteOnlineSelection() }]
            return UIMenu(children: actions)
        }
    }
    func tableView(_ tableView: UITableView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
        guard !busy, authenticated, commander?.operationInProgress != true else { return [] }
        let dragged: [OneDriveItem]
        if tableView === treeView {
            guard let item = treeRows[indexPath.row].last else { return [] }; dragged = [item]
        } else {
            let item = visibleItems[indexPath.row]
            if !selectedIDs.contains(item.id) { selectedIDs = [item.id] }
            dragged = selectedItems
            // Replacing the source cell here can cancel a Catalyst drag before
            // UIKit has installed its lift preview. Update controls, not rows.
            updateNavigation(); onActivate?(); onStateChanged?()
        }
        session.localContext = self
        return dragged.map { item in
            let payload = OneDriveSelection(browser: self, items: [item], generation: generation)
            if tableView === treeView { payload.parentID = treeRows[indexPath.row].dropLast().last?.id }
            let provider = NSItemProvider()
            provider.suggestedName = item.name
            let type = item.isFolder ? UTType.folder : (UTType(filenameExtension: (item.name as NSString).pathExtension) ?? .data)
            provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { [self] completion in
                let progress = Progress(totalUnitCount: 1)
                let task = Task { @MainActor in
                    do {
                        guard payload.generation == self.generation, let client = self.client else { throw OneDriveFailure.message("The OneDrive connection changed.") }
                        let url = try await client.downloadTree(item)
                        self.previewURLs.append(url)
                        completion(url, false, nil); progress.completedUnitCount = 1
                    } catch { completion(nil, false, error) }
                }
                progress.cancellationHandler = { task.cancel() }
                return progress
            }
            let drag = UIDragItem(itemProvider: provider); drag.localObject = payload; return drag
        }
    }
    func tableView(_ tableView: UITableView, canHandle session: UIDropSession) -> Bool {
        guard !busy, authenticated, commander?.operationInProgress != true, !session.items.isEmpty else { return false }
        return session.items.allSatisfy { $0.localObject is OneDriveSelection || $0.localObject is FileEntry || FileDropTransfer.canLoad($0.itemProvider) }
    }
    private func dropParent(_ table: UITableView, session: UIDropSession) -> String? {
        if let row = table.indexPathForRow(at: session.location(in: table)) {
            if table === treeView { return treeRows[row.row].last?.id }
            if visibleItems.indices.contains(row.row), visibleItems[row.row].isFolder { return visibleItems[row.row].id }
        }
        return folders.last?.id
    }
    func tableView(_ tableView: UITableView, dropSessionDidUpdate session: UIDropSession, withDestinationIndexPath destinationIndexPath: IndexPath?) -> UITableViewDropProposal {
        guard self.tableView(tableView, canHandle: session) else { return UITableViewDropProposal(operation: .forbidden) }
        let internalDrop = session.localDragSession != nil
        return UITableViewDropProposal(operation: internalDrop && session.allowsMoveOperation && commander?.moveMode == true ? .move : .copy, intent: .insertIntoDestinationIndexPath)
    }
    func tableView(_ tableView: UITableView, performDropWith coordinator: UITableViewDropCoordinator) {
        guard self.tableView(tableView, canHandle: coordinator.session) else { return }
        onActivate?()
        let destination = dropParent(tableView, session: coordinator.session)
        let selections = coordinator.items.compactMap { $0.dragItem.localObject as? OneDriveSelection }
        if let source = selections.first {
            guard selections.count == coordinator.items.count, selections.allSatisfy({ $0.browser === source.browser && $0.generation == source.generation }) else { return }
            let combined = OneDriveSelection(browser: source.browser, items: selections.flatMap(\.items), generation: source.generation)
            combined.parentID = source.parentID
            receiveOnline(combined, parent: destination, useCurrentFolder: false, move: coordinator.proposal.operation == .move)
        } else {
            let local = coordinator.items.compactMap { $0.dragItem.localObject as? FileEntry }
            if local.count == coordinator.items.count {
                // Our local pane already carries the real URL. Do not round-trip
                // it through a generic provider UTI, which may be public.item.
                receiveLocal(local.map(\.url), parent: destination, useCurrentFolder: false, move: coordinator.proposal.operation == .move)
            } else {
                receiveProviders(coordinator.items.map { $0.dragItem.itemProvider }, parent: destination, useCurrentFolder: false)
            }
        }
    }
    func tableView(_ tableView: UITableView, dragSessionIsRestrictedToDraggingApplication session: UIDragSession) -> Bool { false }
    func tableView(_ tableView: UITableView, dragSessionAllowsMoveOperation session: UIDragSession) -> Bool { true }
}
#endif
