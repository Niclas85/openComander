import UIKit

class TreeNode {
    let entry: FileEntry
    let depth: Int
    var expanded: Bool = false
    var loaded: Bool = false
    var children: [TreeNode] = []
    
    init(entry: FileEntry, depth: Int) {
        self.entry = entry
        self.depth = depth
    }
}

class CommanderPane: NSObject, UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate {
    let title: String
    let accent: String
    weak var viewController: ViewController?
    
    var flatTree: [TreeNode] = []
    var visibleEntries: [FileEntry] = []
    var selectedKeys: Set<String> = []
    
    
    var rootNode: TreeNode!
    var currentDirectory: FileEntry!
    private var backHistory: [FileEntry] = []
    private var forwardHistory: [FileEntry] = []
    private var listingGeneration = 0
    private var listedDirectoryKey: String?
    private var listingPending = false
    private var expandedTreeKeys = Set<String>()
    private var treeGeneration = 0
#if targetEnvironment(macCatalyst)
    private var cloudObserver: CloudDirectoryObserver?
    private var cloudRefreshWork: DispatchWorkItem?
#endif
    private static let listingQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "OpenCommander.directory-listing"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 4
        return queue
    }()
    
    var treeList: UITableView!
    var fileList: UITableView!
    var pathText: UITextField!
    var selectionText: UILabel!
    
    var currentDirectoryBytes: Int64 = -1
    
    init(title: String, root: FileEntry, accent: String, viewController: ViewController) {
        self.title = title
        self.accent = accent
        self.viewController = viewController
        super.init()
        self.setRoot(root)
    }

    deinit {
#if targetEnvironment(macCatalyst)
        cloudObserver?.stop()
        cloudRefreshWork?.cancel()
#endif
    }
    
    func setRoot(_ root: FileEntry, recordHistory: Bool = true) {
        if recordHistory, let current = currentDirectory, current.key() != root.key() {
            backHistory.append(current)
            forwardHistory.removeAll()
        }
        currentDirectory = root
        treeGeneration += 1
        expandedTreeKeys.removeAll()
        rootNode = TreeNode(entry: currentDirectory, depth: 0)
        rootNode.expanded = true
        loadChildren(for: rootNode)
        selectedKeys.removeAll()
    }
    
    private func dp(_ value: CGFloat) -> CGFloat {
        return value
    }
    
    func createView(portrait: Bool, first: Bool) -> UIView {
        guard let vc = viewController, let theme = vc.theme else { return UIView() }
        
        let shell = UIStackView()
        shell.accessibilityIdentifier = "Pane-\(title)"
        shell.axis = .vertical
        shell.spacing = dp(8)
        shell.layer.borderWidth = 1
        shell.layer.borderColor = theme.panelBorder.cgColor
        shell.layer.cornerRadius = 12
        shell.backgroundColor = theme.panelBackground
        shell.isLayoutMarginsRelativeArrangement = true
        shell.layoutMargins = UIEdgeInsets(top: dp(8), left: dp(8), bottom: dp(8), right: dp(8))
        
        let pathRow = UIStackView()
        pathRow.axis = .horizontal
        pathRow.spacing = dp(6)
        pathRow.alignment = .center
        
        pathText = UITextField()
        pathText.textColor = theme.secondaryText
        pathText.font = UIFont.systemFont(ofSize: 11)
        pathText.layer.cornerRadius = 8
        pathText.layer.borderWidth = 1
        pathText.layer.borderColor = theme.pathBorder.cgColor
        pathText.backgroundColor = theme.pathBackground
        let paddingView = UIView(frame: CGRect(x: 0, y: 0, width: dp(8), height: dp(20)))
        pathText.leftView = paddingView
        pathText.leftViewMode = .always
        pathText.delegate = self
        pathText.returnKeyType = .go
        pathText.accessibilityIdentifier = "Path-\(title)"
        
        selectionText = UILabel()
        selectionText.accessibilityIdentifier = "Selection-\(title)"
        selectionText.textColor = theme.secondaryText
        selectionText.font = UIFont.systemFont(ofSize: 11)
        selectionText.textAlignment = .center
        selectionText.layer.cornerRadius = 8
        selectionText.layer.borderWidth = 1
        selectionText.layer.borderColor = theme.pathBorder.cgColor
        selectionText.backgroundColor = theme.pathBackground
        
        let upButton = UIButton(type: .system)
        upButton.setTitle("⬆", for: .normal)
        upButton.titleLabel?.font = UIFont.systemFont(ofSize: 11)
        upButton.layer.cornerRadius = 4
        upButton.layer.borderWidth = 1
        upButton.layer.borderColor = theme.pathBorder.cgColor
        upButton.backgroundColor = theme.buttonBackground
        upButton.setTitleColor(theme.primaryText, for: .normal)
        upButton.contentEdgeInsets = UIEdgeInsets(top: dp(2), left: dp(4), bottom: dp(2), right: dp(4))
        upButton.addTarget(self, action: #selector(navigateUp), for: .touchUpInside)
        upButton.accessibilityIdentifier = "Up-\(title)"
        
        pathRow.addArrangedSubview(upButton)
        pathRow.addArrangedSubview(pathText)
        pathRow.addArrangedSubview(selectionText)
        
        pathText.translatesAutoresizingMaskIntoConstraints = false
        selectionText.translatesAutoresizingMaskIntoConstraints = false
        upButton.translatesAutoresizingMaskIntoConstraints = false
        
        upButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        upButton.setContentHuggingPriority(.required, for: .horizontal)
        upButton.heightAnchor.constraint(equalToConstant: dp(44)).isActive = true
        upButton.widthAnchor.constraint(equalToConstant: dp(44)).isActive = true
        pathText.heightAnchor.constraint(equalToConstant: dp(44)).isActive = true
        
        pathText.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pathText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        selectionText.setContentHuggingPriority(.required, for: .horizontal)
        selectionText.setContentCompressionResistancePriority(.required, for: .horizontal)
        
        shell.addArrangedSubview(pathRow)
        pathRow.setContentHuggingPriority(.required, for: .vertical)
        pathRow.setContentCompressionResistancePriority(.required, for: .vertical)
        
        let columns = UIStackView()
        columns.axis = .horizontal
        columns.spacing = dp(6)
        columns.distribution = .fillEqually
        columns.setContentHuggingPriority(.defaultLow, for: .vertical)
        
        let treeColumn = createColumn(title: L10n.get("tree"), accent: accent, theme: theme)
        treeList = UITableView()
        treeList.accessibilityIdentifier = "TreeList-\(title)"
        treeList.backgroundColor = theme.treeBackground
        treeList.separatorStyle = .singleLine
        treeList.separatorColor = theme.columnBorder
        treeList.dataSource = self
        treeList.delegate = self
        treeList.register(UITableViewCell.self, forCellReuseIdentifier: "TreeCell")
        treeColumn.addArrangedSubview(treeList)
        
        let fileColumn = createColumn(title: L10n.get("files"), accent: accent, theme: theme)
        fileList = UITableView()
        fileList.accessibilityIdentifier = "FileList-\(title)"
        fileList.backgroundColor = theme.fileBackground
        fileList.separatorStyle = .singleLine
        fileList.separatorColor = theme.columnBorder
        fileList.dataSource = self
        fileList.delegate = self
        fileList.dataSource = self
        fileList.rowHeight = 44
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleFileListDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = true
        fileList.addGestureRecognizer(doubleTap)
        
        setupDragAndDrop()
        
        fileList.register(FileCell.self, forCellReuseIdentifier: "FileCell")
        fileColumn.addArrangedSubview(fileList)
        
        columns.addArrangedSubview(treeColumn)
        columns.addArrangedSubview(fileColumn)
        
        treeColumn.translatesAutoresizingMaskIntoConstraints = false
        fileColumn.translatesAutoresizingMaskIntoConstraints = false
        
        shell.addArrangedSubview(columns)
        
        refreshFiles()
        rebuildTree()
        
        return shell
    }
    
    private func createColumn(title: String, accent: String, theme: ViewController.ThemeColors) -> UIStackView {
        let col = UIStackView()
        col.axis = .vertical
        col.layer.borderWidth = 1
        col.layer.borderColor = theme.columnBorder.cgColor
        col.backgroundColor = theme.columnBackground
        col.layer.cornerRadius = 10
        col.clipsToBounds = true
        
        let headerRow = UIStackView()
        headerRow.axis = .horizontal
        headerRow.alignment = .center
        headerRow.backgroundColor = theme.columnHeaderBackground
        headerRow.isLayoutMarginsRelativeArrangement = true
        headerRow.layoutMargins = UIEdgeInsets(top: 0, left: dp(10), bottom: 0, right: dp(10))
        
        let label = UILabel()
        label.text = title
        label.textColor = UIColor(hex: accent)
        label.font = UIFont.boldSystemFont(ofSize: 12)
        
        headerRow.addArrangedSubview(label)
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        headerRow.heightAnchor.constraint(greaterThanOrEqualToConstant: dp(32)).isActive = true
        headerRow.setContentHuggingPriority(.required, for: .vertical)
        headerRow.setContentCompressionResistancePriority(.required, for: .vertical)
        
        col.addArrangedSubview(headerRow)
        return col
    }
    
    @objc func navigateUp() {
        if let parent = currentDirectory.parent {
            openDirectory(parent)
        }
    }

    @objc func navigateBack() {
        guard let previous = backHistory.popLast() else { return }
        forwardHistory.append(currentDirectory)
        showDirectory(previous)
    }

    @objc func navigateForward() {
        guard let next = forwardHistory.popLast() else { return }
        backHistory.append(currentDirectory)
        showDirectory(next)
    }

    private func isEntryInside(_ parent: FileEntry, _ child: FileEntry) -> Bool {
        var cursor: FileEntry? = child
        while let c = cursor {
            if c.key() == parent.key() { return true }
            cursor = c.parent
        }
        return false
    }

    func openDirectory(_ directory: FileEntry) {
        viewController?.activePane = self
        guard currentDirectory.key() != directory.key() else { return }
        backHistory.append(currentDirectory)
        forwardHistory.removeAll()
        showDirectory(directory)
    }

    private func showDirectory(_ directory: FileEntry) {
        currentDirectory = directory
        if !isEntryInside(rootNode.entry, directory) {
            treeGeneration += 1
            rootNode = TreeNode(entry: directory, depth: 0)
            rootNode.expanded = true
            loadChildren(for: rootNode)
        }
        rebuildTree()
        refreshFiles()
    }
    
    func refreshFiles() {
        let directory = currentDirectory!
        listingGeneration += 1
        let generation = listingGeneration
        if listedDirectoryKey != directory.key() {
            visibleEntries.removeAll()
            selectedKeys.removeAll()
        }
        listedDirectoryKey = directory.key()
        listingPending = true
        currentDirectoryBytes = -1
        showDirectoryMessage(visibleEntries.isEmpty ? L10n.get("directory_loading") : nil, retry: false)
        updateSelectionStatus()
        fileList?.reloadData()

#if targetEnvironment(macCatalyst)
        observeCloudDirectory(directory.url)
        Self.listingQueue.addOperation { [weak self] in
            let result = Result { try directory.readChildren(directoriesOnly: false) }
            DispatchQueue.main.async {
                guard let self, self.listingGeneration == generation,
                      self.currentDirectory.key() == directory.key() else { return }
                self.finishListing(result)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.listingGeneration == generation, self.listingPending else { return }
            self.showDirectoryMessage(L10n.get("directory_waiting"), retry: true)
        }
#else
        finishListing(Result { try directory.readChildren(directoriesOnly: false) })
#endif
    }

#if targetEnvironment(macCatalyst)
    private func observeCloudDirectory(_ url: URL) {
        guard cloudObserver?.presentedItemURL != url else { return }
        cloudObserver?.stop()
        cloudObserver = nil
        cloudRefreshWork?.cancel()
        guard HostFileSystem.isCloudStorage(url) else { return }
        cloudObserver = CloudDirectoryObserver(url: url) { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.currentDirectory.url == url else { return }
                self.cloudRefreshWork?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.currentDirectory.url == url,
                          self.viewController?.operationInProgress == false else { return }
                    self.reloadTreeKeepingExpansion()
                    self.refreshFiles()
                }
                self.cloudRefreshWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
            }
        }
    }
#endif

    private func finishListing(_ result: Result<[FileEntry], Error>) {
        listingPending = false
        switch result {
        case .success(let entries):
            visibleEntries = entries
            showDirectoryMessage(entries.isEmpty ? L10n.get("directory_empty") : nil, retry: false)
        case .failure(let error):
            // Do not leave stale rows actionable after a failed refresh.
            visibleEntries.removeAll()
            currentDirectoryBytes = -2
#if targetEnvironment(macCatalyst)
            let message = String(format: L10n.get("directory_error"), error.localizedDescription)
#else
            let message = L10n.get("storage_tree_failed") + "\n" + error.localizedDescription + "\n\n" + L10n.get("help_access_ios")
#endif
            showDirectoryMessage(message, retry: true)
        }
        let newKeys = Set(visibleEntries.map { $0.key() })
        selectedKeys = selectedKeys.intersection(newKeys)
        updateSelectionStatus()
        fileList?.reloadData()
        if case .success = result { scanDirectorySize() }
    }

    private func showDirectoryMessage(_ message: String?, retry: Bool) {
        guard let message else { fileList?.backgroundView = nil; return }
        let container = UIView()
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        let label = UILabel()
        label.text = message
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 13)
        label.textColor = viewController?.theme.secondaryText
        label.accessibilityIdentifier = "DirectoryMessage-\(title)"
        stack.addArrangedSubview(label)
        if retry {
            let button = UIButton(type: .system)
            button.setTitle(L10n.get("directory_retry"), for: .normal)
            button.accessibilityIdentifier = "DirectoryRetry-\(title)"
            button.addAction(UIAction { [weak self] _ in
                self?.reloadTreeKeepingExpansion()
                self?.refreshFiles()
            }, for: .touchUpInside)
            stack.addArrangedSubview(button)
#if !targetEnvironment(macCatalyst)
            let chooseButton = UIButton(type: .system)
            chooseButton.setTitle(L10n.get("choose_another_folder"), for: .normal)
            chooseButton.accessibilityIdentifier = "DirectoryChooseFolder-\(title)"
            chooseButton.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                self.viewController?.activePane = self
                self.viewController?.showComputerLocations()
            }, for: .touchUpInside)
            stack.addArrangedSubview(chooseButton)
#endif
        }
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12)
        ])
        fileList?.backgroundView = container
    }
    
    func rebuildTree() {
        flatTree.removeAll()
        addVisibleNode(rootNode)
        treeList?.reloadData()
    }

    func reloadTreeKeepingExpansion() {
        treeGeneration += 1
        let expandedKeys = Set(flatTree.filter { $0.expanded }.map { $0.entry.key() })
        expandedTreeKeys = expandedKeys
        rootNode = rebuildNode(entry: rootNode.entry, depth: 0, expandedKeys: expandedKeys)
        _ = ensureTreePathVisible(rootNode, target: currentDirectory)
        rebuildTree()
    }

    private func rebuildNode(entry: FileEntry, depth: Int, expandedKeys: Set<String>) -> TreeNode {
        let node = TreeNode(entry: entry, depth: depth)
        node.expanded = depth == 0 || expandedKeys.contains(entry.key())
        if node.expanded {
            loadChildren(for: node)
            node.children = node.children.map { rebuildNode(entry: $0.entry, depth: depth + 1, expandedKeys: expandedKeys) }
        }
        return node
    }

    @discardableResult
    private func ensureTreePathVisible(_ node: TreeNode, target: FileEntry) -> Bool {
        if node.entry.key() == target.key() { return true }
        if !node.loaded { loadChildren(for: node) }
        for child in node.children where isEntryInside(child.entry, target) {
            node.expanded = true
            return ensureTreePathVisible(child, target: target)
        }
        return false
    }

    private func scanDirectorySize() {
        let directory = currentDirectory!
        let generation = listingGeneration
#if targetEnvironment(macCatalyst)
        let directoryPath = directory.url.standardizedFileURL.path
        let homePath = HostFileSystem.homeDirectory.standardizedFileURL.path
        let volumePaths = Set((FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: [.skipHiddenVolumes]
        ) ?? []).map { $0.standardizedFileURL.path })
        if directoryPath == "/" || directoryPath == homePath || volumePaths.contains(directoryPath) ||
            HostFileSystem.isCloudStorage(directory.url) {
            currentDirectoryBytes = -2
            updateSelectionStatus()
            return
        }
#endif
        DispatchQueue.global(qos: .utility).async {
            let bytes = directory.contentBytes()
            DispatchQueue.main.async {
                guard self.listingGeneration == generation, self.currentDirectory.key() == directory.key() else { return }
                self.currentDirectoryBytes = bytes
                self.updateSelectionStatus()
            }
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        let requestedPath = textField.text ?? ""
        textField.resignFirstResponder()
        openTypedPath(requestedPath)
        return true
    }

    private func openTypedPath(_ value: String) {
        var path = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasPrefix("/Documents") {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
            path = documents + String(path.dropFirst("/Documents".count))
        }
        if path.hasSuffix("!/") { path.removeLast(2) }
        guard !path.isEmpty else {
            updateSelectionStatus()
            viewController?.updateGlobalStatus(L10n.get("path_empty"))
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            updateSelectionStatus()
            viewController?.updateGlobalStatus(L10n.get("path_not_found"))
            return
        }
        let entry = FileEntry(url: URL(fileURLWithPath: path), parent: nil)
        guard isDirectory.boolValue || entry.isZipArchive() else {
            updateSelectionStatus()
            viewController?.updateGlobalStatus(L10n.get("path_not_folder"))
            return
        }
        setRoot(entry)
        rebuildTree()
        refreshFiles()
        viewController?.updateGlobalStatus(L10n.get("folder_opened"))
    }
    
    private func addVisibleNode(_ node: TreeNode) {
        flatTree.append(node)
        if !node.expanded { return }
        if !node.loaded { loadChildren(for: node) }
        for child in node.children {
            addVisibleNode(child)
        }
    }
    
    private func loadChildren(for node: TreeNode) {
#if targetEnvironment(macCatalyst)
        // Mark this attempt before rebuilding to avoid duplicate provider requests.
        // A refresh creates new nodes, so failures and empty startup listings retry.
        node.loaded = true
        let generation = treeGeneration
        Self.listingQueue.addOperation { [weak self, weak node] in
            guard let node else { return }
            let entries = (try? node.entry.readChildren(directoriesOnly: true)) ?? []
            DispatchQueue.main.async {
                guard let self, self.treeGeneration == generation else { return }
                node.children = entries.map {
                    let child = TreeNode(entry: $0, depth: node.depth + 1)
                    child.expanded = self.expandedTreeKeys.contains($0.key())
                    return child
                }
                // Expand the current path once provider metadata has arrived.
                _ = self.ensureTreePathVisible(self.rootNode, target: self.currentDirectory)
                self.rebuildTree()
            }
        }
#else
        node.children.removeAll()
        for entry in node.entry.children(directoriesOnly: true) {
            let child = TreeNode(entry: entry, depth: node.depth + 1)
            node.children.append(child)
        }
        node.loaded = true
#endif
    }
    
    func updateSelectionStatus() {
        guard let selectionText = selectionText, let pathText = pathText else { return }
        let sizeStr = currentDirectoryBytes >= 0 ? "\(currentDirectoryBytes) B" : (currentDirectoryBytes == -2 ? "—" : "...")
        selectionText.text = listingPending ? L10n.get("directory_loading") : "\(selectedKeys.count)/\(visibleEntries.count) | \(sizeStr)"
        // A background size scan must not overwrite a path being typed.
        if !pathText.isFirstResponder { pathText.text = currentDirectory.displayPath() }
    }
    
    // MARK: - UITableViewDataSource & Delegate
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if tableView === treeList {
            return flatTree.count
        } else {
            return visibleEntries.count
        }
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if tableView === treeList {
            let cell = tableView.dequeueReusableCell(withIdentifier: "TreeCell", for: indexPath)
            let node = flatTree[indexPath.row]
            
            var indent = ""
            for _ in 0..<node.depth { indent += "  " }
            let prefix = node.expanded ? "▼ " : (node.entry.isDirectoryLike() ? "▶ " : "")
            
            cell.textLabel?.text = "\(indent)\(prefix)\(node.entry.name())"
            cell.textLabel?.font = UIFont.systemFont(ofSize: 12)
            cell.textLabel?.textColor = viewController?.theme.primaryText
            cell.backgroundColor = .clear
            cell.isAccessibilityElement = true
            cell.accessibilityIdentifier = "Tree-\(title)-\(node.entry.name())"
            cell.accessibilityLabel = node.entry.name()
            return cell
        } else {
            let cell = tableView.dequeueReusableCell(withIdentifier: "FileCell", for: indexPath) as! FileCell
            let entry = visibleEntries[indexPath.row]
            
            cell.configure(with: entry, theme: viewController!.theme, isSelected: selectedKeys.contains(entry.key()))
            cell.isAccessibilityElement = true
            cell.accessibilityIdentifier = "File-\(title)-\(entry.name())"
            cell.accessibilityLabel = entry.name()
            cell.accessibilityTraits = selectedKeys.contains(entry.key()) ? [.button, .selected] : [.button]
            return cell
        }
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        viewController?.activePane = self
        
        if tableView === treeList {
            let node = flatTree[indexPath.row]
            if currentDirectory.key() != node.entry.key() {
                backHistory.append(currentDirectory)
                forwardHistory.removeAll()
            }
            currentDirectory = node.entry
            if !node.loaded { loadChildren(for: node) }
            node.expanded.toggle()
            rebuildTree()
            refreshFiles()
        } else {
            let entry = visibleEntries[indexPath.row]
            
            if selectedKeys.contains(entry.key()) {
                selectedKeys.remove(entry.key())
            } else {
                selectedKeys.insert(entry.key())
            }
            updateSelectionStatus()
            tableView.reloadData()
        }
    }
    
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 44
    }

    @objc private func handleFileListDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended,
              let indexPath = fileList.indexPathForRow(at: recognizer.location(in: fileList)),
              indexPath.row < visibleEntries.count else { return }
        let entry = visibleEntries[indexPath.row]
        viewController?.activePane = self
        if entry.opensInPaneByDefault() {
            openDirectory(entry)
        } else {
            viewController?.openExternal(entry)
        }
    }
}

#if targetEnvironment(macCatalyst)
extension CommanderPane {
    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath,
                   point: CGPoint) -> UIContextMenuConfiguration? {
        let entry = tableView === treeList ? flatTree[indexPath.row].entry : visibleEntries[indexPath.row]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self, let controller = self.viewController else { return nil }
            var actions: [UIAction] = [
                UIAction(title: L10n.get("open"), image: UIImage(systemName: "arrow.up.forward.app")) { _ in
                    controller.activePane = self
                    if entry.opensInPaneByDefault() { self.openDirectory(entry) }
                    else { controller.openExternal(entry) }
                },
                UIAction(title: L10n.get("open_with"), image: UIImage(systemName: "app")) { _ in
                    controller.openDesktopFile(entry, chooseApplication: true)
                },
                UIAction(title: L10n.get("preview"), image: UIImage(systemName: "eye")) { _ in
                    controller.previewFile(entry)
                }
            ]
            if entry.isDirectoryLike() {
                actions.append(UIAction(title: L10n.get("browse_contents"), image: UIImage(systemName: "folder")) { _ in
                    self.openDirectory(entry)
                })
            }
            return UIMenu(children: actions)
        }
    }
}
#endif

import UIKit
import UniformTypeIdentifiers

extension CommanderPane: UITableViewDragDelegate, UITableViewDropDelegate {
    func setupDragAndDrop() {
        fileList.dragDelegate = self
        fileList.dropDelegate = self
        fileList.dragInteractionEnabled = true
        treeList.dragDelegate = self
        treeList.dropDelegate = self
        treeList.dragInteractionEnabled = true
    }
    
    // MARK: - Drag Delegate
    
    func tableView(_ tableView: UITableView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
        guard indexPath.section == 0 else { return [] }
        let entries = tableView === treeList ? flatTree.map(\.entry) : visibleEntries
        guard entries.indices.contains(indexPath.row) else { return [] }
        let entry = entries[indexPath.row]
        if entry.isUpButton || !entry.isPhysical() { return [] }
        
        if !selectedKeys.contains(entry.key()) {
            selectedKeys.insert(entry.key())
            updateSelectionStatus()
        }
        
        viewController?.activeDragPane = self
        session.localContext = self
        let dragged = tableView === treeList ? [entry] : visibleEntries.filter { selectedKeys.contains($0.key()) }
        return dragged.compactMap { entry in
            guard entry.isPhysical(), !entry.isUpButton else { return nil }
            let provider = FileDropTransfer.provider(for: entry.url)
            let item = UIDragItem(itemProvider: provider)
            item.localObject = entry
            return item
        }
    }
    
    // MARK: - Drop Delegate
    
    func tableView(_ tableView: UITableView, canHandle session: UIDropSession) -> Bool {
        guard viewController?.externalDropInProgress != true, viewController?.fileOperationInProgress != true,
              viewController?.presentedViewController == nil, !session.items.isEmpty else { return false }
        if session.localDragSession?.localContext is CommanderPane {
            return session.items.allSatisfy { $0.localObject is FileEntry }
        }
        return session.items.allSatisfy { FileDropTransfer.canLoad($0.itemProvider) }
    }

    private func targetForDrop(in tableView: UITableView, session: UIDropSession) -> FileEntry? {
        // Use the actual row under the pointer, not UIKit's insertion index.
        if let index = tableView.indexPathForRow(at: session.location(in: tableView)), index.section == 0 {
            if tableView === treeList, flatTree.indices.contains(index.row) { return flatTree[index.row].entry }
            if tableView === fileList, visibleEntries.indices.contains(index.row) {
                let entry = visibleEntries[index.row]
                if entry.isDirectoryLike() { return entry }
            }
        }
        return currentDirectory
    }
    
    func tableView(_ tableView: UITableView, dropSessionDidUpdate session: UIDropSession, withDestinationIndexPath destinationIndexPath: IndexPath?) -> UITableViewDropProposal {
        guard self.tableView(tableView, canHandle: session),
              let target = targetForDrop(in: tableView, session: session), target.canWriteDirectory() else {
            return UITableViewDropProposal(operation: .forbidden)
        }
        let internalDrag = session.localDragSession?.localContext is CommanderPane
        let operation: UIDropOperation = internalDrag && session.allowsMoveOperation && viewController?.moveMode == true ? .move : .copy
        return UITableViewDropProposal(operation: operation, intent: .insertIntoDestinationIndexPath)
    }
    
    func tableView(_ tableView: UITableView, performDropWith coordinator: UITableViewDropCoordinator) {
        guard self.tableView(tableView, canHandle: coordinator.session),
              let target = targetForDrop(in: tableView, session: coordinator.session), target.canWriteDirectory(),
              let controller = viewController else { return }
        controller.activePane = self
        if let sourcePane = coordinator.session.localDragSession?.localContext as? CommanderPane {
            // Use the actual drag payload, never a selection that may have changed.
            let sources = coordinator.items.compactMap { $0.dragItem.localObject as? FileEntry }
            controller.runFileOperation(sources: sources, sourcePane: sourcePane, targetDirectory: target,
                                        move: coordinator.proposal.operation == .move)
        } else {
            controller.receiveExternalDrop(providers: coordinator.items.map { $0.dragItem.itemProvider }, targetDirectory: target)
        }
    }

    func tableView(_ tableView: UITableView, dragSessionIsRestrictedToDraggingApplication session: UIDragSession) -> Bool { false }

    func tableView(_ tableView: UITableView, dragSessionAllowsMoveOperation session: UIDragSession) -> Bool { true }

    func tableView(_ tableView: UITableView, dragSessionDidEnd session: UIDragSession) {
        if viewController?.activeDragPane === self {
            viewController?.activeDragPane = nil
        }
        // Finder may have moved a directly exported URL; refresh, but never
        // delete source files merely because a drag session ended.
        viewController?.refreshAllPanes(clearSelectionIn: [])
    }
}

extension CommanderPane {
    func selectedEntries() -> [FileEntry] {
        return visibleEntries.filter { selectedKeys.contains($0.key()) }
    }
}
import UIKit

class FileCell: UITableViewCell {
    let iconView = FileIconView()
    let nameLabel = UILabel()
    let sizeLabel = UILabel()
    let dateLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.backgroundColor = .clear
        
        nameLabel.font = UIFont.systemFont(ofSize: 12)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        
        sizeLabel.font = UIFont.systemFont(ofSize: 10)
        sizeLabel.textColor = .gray
        sizeLabel.translatesAutoresizingMaskIntoConstraints = false
        
        dateLabel.font = UIFont.systemFont(ofSize: 10)
        dateLabel.textColor = .gray
        dateLabel.translatesAutoresizingMaskIntoConstraints = false
        
        contentView.addSubview(iconView)
        contentView.addSubview(nameLabel)
        contentView.addSubview(sizeLabel)
        contentView.addSubview(dateLabel)
        
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),
            
            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            nameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 2),
            nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            
            sizeLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            sizeLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -2),
            
            dateLabel.leadingAnchor.constraint(equalTo: sizeLabel.trailingAnchor, constant: 8),
            dateLabel.bottomAnchor.constraint(equalTo: sizeLabel.bottomAnchor)
        ])
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func configure(with entry: FileEntry, theme: ViewController.ThemeColors, isSelected: Bool) {
        nameLabel.text = entry.name()
        nameLabel.textColor = theme.primaryText
        
        if entry.isDirectoryLike() {
            sizeLabel.text = "DIR"
            iconView.kind = "folder"
        } else {
            let s = entry.size()
            if s > 1024 * 1024 {
                sizeLabel.text = String(format: "%.1f MB", Double(s) / (1024.0 * 1024.0))
            } else if s > 1024 {
                sizeLabel.text = String(format: "%.1f KB", Double(s) / 1024.0)
            } else {
                sizeLabel.text = "\(s) B"
            }
            
            let mime = entry.mimeType()
            let ext = entry.url.pathExtension.lowercased()
            if mime.starts(with: "image/") { iconView.kind = "image" }
            else if mime.starts(with: "video/") { iconView.kind = "video" }
            else if mime.starts(with: "audio/") { iconView.kind = "audio" }
            else if ext == "pdf" { iconView.kind = "pdf" }
            else if ext == "zip" { iconView.kind = "archive" }
            else if ext == "apk" { iconView.kind = "apk" }
            else if ext == "db" || ext == "sqlite" { iconView.kind = "database" }
            else if ext == "html" || ext == "xml" || ext == "json" || ext == "swift" || ext == "java" || ext == "py" { iconView.kind = "code" }
            else if ext == "txt" || ext == "md" || ext == "log" { iconView.kind = "text" }
            else {
                iconView.kind = "file"
                iconView.text = String(ext.prefix(4))
            }
        }
        iconView.setNeedsDisplay()
        
        if entry.modified() > 0 {
            let d = Date(timeIntervalSince1970: TimeInterval(entry.modified() / 1000))
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd HH:mm"
            dateLabel.text = df.string(from: d)
        } else {
            dateLabel.text = ""
        }
        
        backgroundColor = isSelected ? theme.selectionBackground : .clear
    }
}
import UIKit

class FileIconView: UIView {
    var kind: String = "file"
    var text: String = ""

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        
        let w = rect.width
        let h = rect.height
        
        let fillPath = UIBezierPath(roundedRect: rect, cornerRadius: 4)
        UIColor(hex: iconFill(kind: kind)).setFill()
        fillPath.fill()
        
        context.setStrokeColor(UIColor.white.cgColor)
        context.setLineWidth(2)
        
        let box = rect
        if kind == "folder" {
            let path = UIBezierPath()
            path.move(to: CGPoint(x: box.minX + box.width * 0.15, y: box.minY + box.height * 0.35))
            path.addLine(to: CGPoint(x: box.minX + box.width * 0.40, y: box.minY + box.height * 0.35))
            path.addLine(to: CGPoint(x: box.minX + box.width * 0.50, y: box.minY + box.height * 0.20))
            path.addLine(to: CGPoint(x: box.maxX - box.width * 0.15, y: box.minY + box.height * 0.20))
            path.addLine(to: CGPoint(x: box.maxX - box.width * 0.15, y: box.maxY - box.height * 0.20))
            path.addLine(to: CGPoint(x: box.minX + box.width * 0.15, y: box.maxY - box.height * 0.20))
            path.close()
            path.stroke()
        } else if kind == "image" {
            let frame = CGRect(x: box.minX + box.width * 0.15, y: box.minY + box.height * 0.2, width: box.width * 0.7, height: box.height * 0.6)
            let path = UIBezierPath(roundedRect: frame, cornerRadius: 3)
            path.stroke()
            
            let mountain = UIBezierPath()
            mountain.move(to: CGPoint(x: frame.minX + frame.width * 0.12, y: frame.maxY - frame.height * 0.12))
            mountain.addLine(to: CGPoint(x: frame.minX + frame.width * 0.40, y: frame.minY + frame.height * 0.56))
            mountain.addLine(to: CGPoint(x: frame.minX + frame.width * 0.56, y: frame.maxY - frame.height * 0.18))
            mountain.addLine(to: CGPoint(x: frame.minX + frame.width * 0.70, y: frame.minY + frame.height * 0.48))
            mountain.addLine(to: CGPoint(x: frame.maxX - frame.width * 0.10, y: frame.maxY - frame.height * 0.12))
            mountain.stroke()
        } else if kind == "video" {
            let frame = CGRect(x: box.minX + box.width * 0.18, y: box.minY + box.height * 0.24, width: box.width * 0.64, height: box.height * 0.52)
            let path = UIBezierPath(roundedRect: frame, cornerRadius: 3)
            path.stroke()
            
            let play = UIBezierPath()
            play.move(to: CGPoint(x: frame.minX + frame.width * 0.40, y: frame.minY + frame.height * 0.28))
            play.addLine(to: CGPoint(x: frame.minX + frame.width * 0.40, y: frame.maxY - frame.height * 0.28))
            play.addLine(to: CGPoint(x: frame.minX + frame.width * 0.65, y: frame.minY + frame.height * 0.50))
            play.close()
            UIColor.white.setFill()
            play.fill()
        } else if kind == "audio" {
            let note = UIBezierPath()
            note.move(to: CGPoint(x: box.minX + box.width * 0.35, y: box.maxY - box.height * 0.25))
            note.addLine(to: CGPoint(x: box.minX + box.width * 0.35, y: box.minY + box.height * 0.20))
            note.addLine(to: CGPoint(x: box.minX + box.width * 0.70, y: box.minY + box.height * 0.30))
            note.addLine(to: CGPoint(x: box.minX + box.width * 0.70, y: box.maxY - box.height * 0.35))
            note.stroke()
            
            let dot1 = UIBezierPath(arcCenter: CGPoint(x: box.minX + box.width * 0.30, y: box.maxY - box.height * 0.25), radius: 3, startAngle: 0, endAngle: 2 * .pi, clockwise: true)
            UIColor.white.setFill()
            dot1.fill()
            
            let dot2 = UIBezierPath(arcCenter: CGPoint(x: box.minX + box.width * 0.65, y: box.maxY - box.height * 0.35), radius: 3, startAngle: 0, endAngle: 2 * .pi, clockwise: true)
            dot2.fill()
        } else if kind == "code" {
            drawTextIcon(box: box, txt: "</>")
        } else if kind == "archive" {
            let zip = UIBezierPath()
            zip.move(to: CGPoint(x: box.minX + box.width * 0.3, y: box.minY + box.height * 0.2))
            zip.addLine(to: CGPoint(x: box.maxX - box.width * 0.3, y: box.minY + box.height * 0.2))
            zip.addLine(to: CGPoint(x: box.maxX - box.width * 0.3, y: box.maxY - box.height * 0.2))
            zip.addLine(to: CGPoint(x: box.minX + box.width * 0.3, y: box.maxY - box.height * 0.2))
            zip.close()
            zip.stroke()
            
            let mid = box.minX + box.width * 0.5
            let teeth = UIBezierPath()
            teeth.move(to: CGPoint(x: mid, y: box.minY + box.height * 0.2))
            teeth.addLine(to: CGPoint(x: mid, y: box.minY + box.height * 0.5))
            teeth.stroke()
        } else if kind == "apk" {
            let droid = UIBezierPath()
            droid.move(to: CGPoint(x: box.minX + box.width * 0.3, y: box.minY + box.height * 0.4))
            droid.addLine(to: CGPoint(x: box.maxX - box.width * 0.3, y: box.minY + box.height * 0.4))
            droid.addLine(to: CGPoint(x: box.maxX - box.width * 0.3, y: box.maxY - box.height * 0.3))
            droid.addLine(to: CGPoint(x: box.minX + box.width * 0.3, y: box.maxY - box.height * 0.3))
            droid.close()
            droid.stroke()
            
            let head = UIBezierPath()
            head.addArc(withCenter: CGPoint(x: box.minX + box.width * 0.5, y: box.minY + box.height * 0.35), radius: box.width * 0.2, startAngle: .pi, endAngle: 0, clockwise: true)
            head.stroke()
        } else if kind == "database" {
            let db = UIBezierPath(ovalIn: CGRect(x: box.minX + box.width * 0.25, y: box.minY + box.height * 0.2, width: box.width * 0.5, height: box.height * 0.15))
            db.stroke()
            let db2 = UIBezierPath(ovalIn: CGRect(x: box.minX + box.width * 0.25, y: box.minY + box.height * 0.4, width: box.width * 0.5, height: box.height * 0.15))
            db2.stroke()
            let db3 = UIBezierPath(ovalIn: CGRect(x: box.minX + box.width * 0.25, y: box.minY + box.height * 0.6, width: box.width * 0.5, height: box.height * 0.15))
            db3.stroke()
        } else if kind == "pdf" || kind == "doc" || kind == "sheet" || kind == "slide" {
            drawTextIcon(box: box, txt: kind.uppercased())
        } else {
            drawTextIcon(box: box, txt: text.isEmpty ? "FILE" : text.uppercased())
        }
    }
    
    private func drawTextIcon(box: CGRect, txt: String) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: txt.count > 2 ? 8 : 10),
            .foregroundColor: UIColor.white
        ]
        let size = (txt as NSString).size(withAttributes: attrs)
        let rect = CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height)
        (txt as NSString).draw(in: rect, withAttributes: attrs)
    }

    private func iconFill(kind: String) -> String {
        if kind == "folder" { return "#F2A91B" }
        if kind == "image" { return "#2F80ED" }
        if kind == "video" { return "#7C3AED" }
        if kind == "audio" { return "#10A36F" }
        if kind == "pdf" { return "#E53935" }
        if kind == "doc" { return "#2B6CB0" }
        if kind == "sheet" { return "#16803A" }
        if kind == "slide" { return "#D97706" }
        if kind == "archive" { return "#8B5CF6" }
        if kind == "apk" { return "#16A34A" }
        if kind == "code" { return "#475569" }
        if kind == "database" { return "#0F766E" }
        if kind == "font" { return "#9333EA" }
        return "#64748B"
    }
}
