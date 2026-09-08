import UIKit
import ZIPFoundation
import UniformTypeIdentifiers


enum OperationType {
    case delete(files: [(originalUrl: URL, backupUrl: URL)])
    case move(files: [(source: URL, destination: URL, replacedBackup: URL?)])
    case copy(files: [(source: URL, destination: URL, replacedBackup: URL?)])
    case zip(url: URL)
    case rename(originalUrl: URL, newUrl: URL)
}


private final class CompactActionToolbar: UIView {
    private let buttons: [UIButton]
    private let gap: CGFloat = 2
    private let horizontalPadding: CGFloat = 6

    init(buttons: [UIButton]) {
        self.buttons = buttons
        super.init(frame: .zero)
        for button in buttons {
            button.translatesAutoresizingMaskIntoConstraints = true
            button.constraints.filter { $0.firstAttribute == .height }.forEach { $0.isActive = false }
            button.titleLabel?.numberOfLines = 1
            button.contentEdgeInsets = UIEdgeInsets(top: 4, left: 3, bottom: 4, right: 3)
            addSubview(button)
        }
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 28)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0 else { return }
        func widths(fontSize: CGFloat) -> [CGFloat] {
            let font = UIFont.systemFont(ofSize: fontSize)
            return buttons.map {
                max(24, ceil((($0.currentTitle ?? "") as NSString).size(withAttributes: [.font: font]).width) + horizontalPadding)
            }
        }
        let spacing = CGFloat(max(0, buttons.count - 1)) * gap
        // Keep every complete localized label in one row, including Move.
        // Use one shared font size so longer translations remain consistent.
        var fontSize: CGFloat = 10
        var sizes = widths(fontSize: fontSize)
        while sizes.reduce(0, +) + spacing > bounds.width && fontSize > 1 {
            fontSize -= 0.1
            sizes = widths(fontSize: fontSize)
        }
        let extra = max(0, bounds.width - sizes.reduce(0, +) - spacing) / CGFloat(buttons.count)
        var x: CGFloat = 0
        for (index, button) in buttons.enumerated() {
            button.titleLabel?.font = .systemFont(ofSize: fontSize)
            button.frame = CGRect(x: x, y: 0, width: sizes[index] + extra, height: bounds.height)
            x += sizes[index] + extra + gap
        }
    }
}

class ViewController: UIViewController {
    private struct FileClipboard {
        let urls: [URL]
        let move: Bool
    }

    var operationHistory: [OperationType] = [] {
        didSet {
            DispatchQueue.main.async {
                self.rebuildHistoryPanel()
            }
        }
    }

    struct ThemeColors {
        let appBackground: UIColor
        let headerBackground: UIColor
        let headerText: UIColor
        let panelBackground: UIColor
        let panelBorder: UIColor
        let columnBackground: UIColor
        let columnBorder: UIColor
        let columnHeaderBackground: UIColor
        let primaryText: UIColor
        let secondaryText: UIColor
        let treeBackground: UIColor
        let fileBackground: UIColor
        let pathBackground: UIColor
        let pathBorder: UIColor
        let buttonBackground: UIColor
        let buttonBorder: UIColor
        let buttonText: UIColor
        let selectionBackground: UIColor

        init(darkMode: Bool) {
            if darkMode {
                selectionBackground = UIColor(hex: "#344961")
                appBackground = UIColor(hex: "#1A1B1E")
                headerBackground = UIColor(hex: "#2B2D31")
                headerText = UIColor(hex: "#F2F3F5")
                panelBackground = UIColor(hex: "#313338")
                panelBorder = UIColor(hex: "#1E1F22")
                columnBackground = UIColor(hex: "#2B2D31")
                columnBorder = UIColor(hex: "#1E1F22")
                columnHeaderBackground = UIColor(hex: "#232428")
                primaryText = UIColor(hex: "#DBDEE1")
                secondaryText = UIColor(hex: "#B5BAC1")
                treeBackground = UIColor(hex: "#2B2D31")
                fileBackground = UIColor(hex: "#313338")
                pathBackground = UIColor(hex: "#1E1F22")
                pathBorder = UIColor(hex: "#232428")
                buttonBackground = UIColor(hex: "#383A40")
                buttonBorder = UIColor(hex: "#2B2D31")
                buttonText = UIColor(hex: "#DBDEE1")
            } else {
                selectionBackground = UIColor(hex: "#FFF4D8")
                appBackground = UIColor(hex: "#E8EAED")
                headerBackground = UIColor(hex: "#FFFFFF")
                headerText = UIColor(hex: "#202124")
                panelBackground = UIColor(hex: "#FFFFFF")
                panelBorder = UIColor(hex: "#DADCE0")
                columnBackground = UIColor(hex: "#F8F9FA")
                columnBorder = UIColor(hex: "#E8EAED")
                columnHeaderBackground = UIColor(hex: "#F1F3F4")
                primaryText = UIColor(hex: "#202124")
                secondaryText = UIColor(hex: "#5F6368")
                treeBackground = UIColor(hex: "#F8F9FA")
                fileBackground = UIColor(hex: "#FFFFFF")
                pathBackground = UIColor(hex: "#F1F3F4")
                pathBorder = UIColor(hex: "#E8EAED")
                buttonBackground = UIColor(hex: "#F8F9FA")
                buttonBorder = UIColor(hex: "#DADCE0")
                buttonText = UIColor(hex: "#3C4043")
            }
        }
    }

    var darkMode = false
    var theme: ThemeColors!

    var leftPane: CommanderPane!
    var rightPane: CommanderPane!
    weak var activePane: CommanderPane?
    weak var activeDragPane: CommanderPane?
    var externalDropInProgress = false
    private(set) var fileOperationInProgress = false
    var historyExpanded = false
    var moveMode = false
    private var operationInProgress = false
    private var fileClipboard: FileClipboard?
    private weak var folderPickerPane: CommanderPane?
    private var folderPickerAppliesToBothPanes = false
    private weak var storageLocationsStack: UIStackView?
    private var storageLocationsRefreshGeneration = 0
    private var securityScopedURLs: [URL] = []
    private var fullDiskAccessStatus: HostFileSystem.FullDiskAccessStatus = .unavailable

    var undoButton: UIButton!
    var deleteButton: UIButton!
    var renameButton: UIButton!
    var zipButton: UIButton!
    var historyButton: UIButton!
    var languageButton: UIButton!
    var openFolderButton: UIButton!
    var darkModeSwitch: UISwitch!
    var documentInteractionController: UIDocumentInteractionController?

    var historyPanel: UIView!
    var progressText: UILabel!
    var progressBar: UIProgressView!
    var globalStatus: UILabel!

    func dp(_ value: CGFloat) -> CGFloat {
        return value
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        darkMode = UserDefaults.standard.bool(forKey: "dark_mode")
        let savedLanguage = UserDefaults.standard.string(forKey: "language") ?? ""
        L10n.currentLanguage = L10n.resolvedLanguage(savedLanguage.isEmpty ? (Locale.current.identifier) : savedLanguage)
        theme = ThemeColors(darkMode: darkMode)
        
#if targetEnvironment(macCatalyst)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActiveForAccessCheck),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        let downloadsURL = HostFileSystem.downloadsDirectory
        let leftURL = restoreFolderLocation(forPane: "1") ?? URL(fileURLWithPath: "/", isDirectory: true)
        let rightURL = restoreFolderLocation(forPane: "2") ?? downloadsURL
#else
        let rootUrl = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let leftURL = restoreFolderLocation(forPane: "1") ?? rootUrl
        let rightURL = restoreFolderLocation(forPane: "2") ?? rootUrl
#endif
        
        leftPane = CommanderPane(title: "1", root: FileEntry(url: leftURL, parent: nil), accent: "#1E66C1", viewController: self)
        rightPane = CommanderPane(title: "2", root: FileEntry(url: rightURL, parent: nil), accent: "#1F8A5B", viewController: self)
        activePane = leftPane
        
        buildLayout()
        maybeShowFirstRunHelp()
    }

    @objc private func applicationDidBecomeActiveForAccessCheck() {
#if targetEnvironment(macCatalyst)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            self.refreshFullDiskAccessStatus(showFeedback: false)
            self.reloadStorageLocationsBar()
        }
#endif
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { _ in
            self.rebuildApp(status: L10n.get("ready"))
        }
    }

    private func buildLayout() {
        self.view.subviews.forEach { $0.removeFromSuperview() }
        theme = ThemeColors(darkMode: darkMode)
        self.view.semanticContentAttribute = L10n.isRightToLeft ? .forceRightToLeft : .forceLeftToRight
        
        let portrait = self.view.bounds.height > self.view.bounds.width
        
        let rootStack = UIStackView()
        rootStack.axis = .vertical
        rootStack.alignment = .fill
        rootStack.distribution = .fill
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        
        let baseTopPadding = portrait ? dp(10) : dp(4)
        let baseBottomPadding = portrait ? dp(8) : dp(4)
        let sidePadding = portrait ? dp(10) : dp(6)
        
        self.view.backgroundColor = theme.appBackground
        self.view.addSubview(rootStack)
        
        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.topAnchor, constant: baseTopPadding),
            rootStack.bottomAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.bottomAnchor, constant: -baseBottomPadding),
            rootStack.leadingAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.leadingAnchor, constant: sidePadding),
            rootStack.trailingAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.trailingAnchor, constant: -sidePadding)
        ])

        let topBar = createTopBar()
        topBar.setContentHuggingPriority(.required, for: .vertical)
        topBar.setContentCompressionResistancePriority(.required, for: .vertical)
        rootStack.addArrangedSubview(topBar)
        rootStack.setCustomSpacing(portrait ? dp(6) : dp(3), after: topBar)

#if targetEnvironment(macCatalyst)
        let storageBar = createStorageLocationsBar()
        storageBar.setContentHuggingPriority(.required, for: .vertical)
        storageBar.setContentCompressionResistancePriority(.required, for: .vertical)
        rootStack.addArrangedSubview(storageBar)
        rootStack.setCustomSpacing(portrait ? dp(6) : dp(3), after: storageBar)
#endif

        historyPanel = UIView()
        historyPanel.layer.borderWidth = 1
        historyPanel.layer.borderColor = theme.panelBorder.cgColor
        historyPanel.layer.cornerRadius = 8
        historyPanel.backgroundColor = theme.panelBackground
        historyPanel.isHidden = !historyExpanded
        historyPanel.setContentHuggingPriority(.required, for: .vertical)
        historyPanel.setContentCompressionResistancePriority(.required, for: .vertical)
        rootStack.addArrangedSubview(historyPanel)
        rootStack.setCustomSpacing(dp(8), after: historyPanel)

        let commandersStack = UIStackView()
        commandersStack.axis = portrait ? .vertical : .horizontal
        commandersStack.distribution = .fillEqually
        commandersStack.spacing = dp(8)
        commandersStack.setContentHuggingPriority(.defaultLow, for: .vertical)
        
        commandersStack.addArrangedSubview(leftPane.createView(portrait: portrait, first: true))
        commandersStack.addArrangedSubview(rightPane.createView(portrait: portrait, first: false))
        
        rootStack.addArrangedSubview(commandersStack)

        progressText = UILabel()
        progressText.textColor = theme.secondaryText
        progressText.font = UIFont.boldSystemFont(ofSize: 13)
        progressText.numberOfLines = 0
        
        let progressContainer = UIView()
        progressContainer.addSubview(progressText)
        progressText.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            progressText.topAnchor.constraint(equalTo: progressContainer.topAnchor, constant: dp(8)),
            progressText.bottomAnchor.constraint(equalTo: progressContainer.bottomAnchor, constant: -dp(3)),
            progressText.leadingAnchor.constraint(equalTo: progressContainer.leadingAnchor, constant: dp(4)),
            progressText.trailingAnchor.constraint(equalTo: progressContainer.trailingAnchor, constant: -dp(4))
        ])
        progressContainer.setContentHuggingPriority(.required, for: .vertical)
        progressContainer.setContentCompressionResistancePriority(.required, for: .vertical)
        rootStack.addArrangedSubview(progressContainer)

        progressBar = UIProgressView(progressViewStyle: .default)
        progressBar.isHidden = true
        let pbContainer = UIView()
        pbContainer.addSubview(progressBar)
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            progressBar.topAnchor.constraint(equalTo: pbContainer.topAnchor),
            progressBar.bottomAnchor.constraint(equalTo: pbContainer.bottomAnchor),
            progressBar.leadingAnchor.constraint(equalTo: pbContainer.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: pbContainer.trailingAnchor),
            pbContainer.heightAnchor.constraint(equalToConstant: dp(8))
        ])
        pbContainer.setContentHuggingPriority(.required, for: .vertical)
        pbContainer.setContentCompressionResistancePriority(.required, for: .vertical)
        rootStack.addArrangedSubview(pbContainer)

        globalStatus = UILabel()
        globalStatus.textColor = theme.secondaryText
        globalStatus.font = UIFont.systemFont(ofSize: 12)
        globalStatus.text = L10n.get("ready")
        globalStatus.accessibilityIdentifier = "GlobalStatus"
        
        let statusContainer = UIView()
        statusContainer.addSubview(globalStatus)
        globalStatus.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            globalStatus.topAnchor.constraint(equalTo: statusContainer.topAnchor, constant: dp(6)),
            globalStatus.bottomAnchor.constraint(equalTo: statusContainer.bottomAnchor),
            globalStatus.leadingAnchor.constraint(equalTo: statusContainer.leadingAnchor, constant: dp(4)),
            globalStatus.trailingAnchor.constraint(equalTo: statusContainer.trailingAnchor, constant: -dp(4))
        ])
        statusContainer.setContentHuggingPriority(.required, for: .vertical)
        statusContainer.setContentCompressionResistancePriority(.required, for: .vertical)
        rootStack.addArrangedSubview(statusContainer)
        rebuildHistoryPanel()
    }

    private func createTopBar() -> UIView {
        let landscape = view.bounds.width > view.bounds.height
        let topBar = UIStackView()
        topBar.axis = .vertical
        topBar.alignment = .fill
        topBar.spacing = 4
        topBar.layer.borderWidth = 1
        topBar.layer.borderColor = theme.panelBorder.cgColor
        topBar.layer.cornerRadius = 12
        topBar.backgroundColor = theme.headerBackground
        topBar.isLayoutMarginsRelativeArrangement = true
        topBar.layoutMargins = UIEdgeInsets(top: 4, left: 6, bottom: 6, right: 6)

        let title = UILabel()
        title.text = L10n.get("app_name")
        title.textColor = theme.headerText
        title.font = UIFont.boldSystemFont(ofSize: landscape ? 14 : 17)
        title.adjustsFontSizeToFitWidth = true
        title.minimumScaleFactor = 0.7
        let titleRow = UIStackView(arrangedSubviews: [title])
        titleRow.axis = .horizontal
        titleRow.alignment = .center
        titleRow.spacing = 4
        titleRow.accessibilityIdentifier = "TitleToolbar"
        topBar.addArrangedSubview(titleRow)

        undoButton = miniButton(label: L10n.get("undo"))
        undoButton.accessibilityIdentifier = "UndoButton"
        tintButton(button: undoButton, lightFill: "#D8EAFF", lightStroke: "#4F96E8", lightText: "#073E7D", darkFill: "#123A66", darkStroke: "#3B82F6", darkText: "#E6F2FF")
        undoButton.addTarget(self, action: #selector(undoLastOperation), for: .touchUpInside)

        deleteButton = miniButton(label: L10n.get("delete_button"))
        deleteButton.accessibilityIdentifier = "DeleteButton"
        tintButton(button: deleteButton, lightFill: "#FFE4E0", lightStroke: "#E88778", lightText: "#7A2017", darkFill: "#51231F", darkStroke: "#C24131", darkText: "#FFECE8")
        deleteButton.addTarget(self, action: #selector(confirmDeleteSelection), for: .touchUpInside)

        renameButton = miniButton(label: L10n.get("rename_button"))
        renameButton.accessibilityIdentifier = "RenameButton"
        tintButton(button: renameButton, lightFill: "#E8F1FF", lightStroke: "#78A9E8", lightText: "#174A7E", darkFill: "#1F344D", darkStroke: "#4F7FAF", darkText: "#E8F2FF")
        renameButton.addTarget(self, action: #selector(showRenameDialog), for: .touchUpInside)

        let operationButton = miniButton(label: moveMode ? L10n.get("operation_mode_move") : L10n.get("operation_mode_copy"))
        operationButton.accessibilityIdentifier = "OperationButton"
        operationButton.isSelected = moveMode
        operationButton.accessibilityValue = moveMode ? L10n.get("operation_mode_move") : L10n.get("operation_mode_copy")
        if moveMode {
            operationButton.accessibilityTraits.insert(.selected)
        }
        tintButton(button: operationButton, lightFill: "#E9F8EF", lightStroke: "#91D5A7", lightText: "#1F6B3A", darkFill: "#173F2A", darkStroke: "#2D8A50", darkText: "#DDFBE8")
        operationButton.addTarget(self, action: #selector(toggleOperationMode(_:)), for: .touchUpInside)

        historyButton = miniButton(label: historyExpanded ? L10n.get("history_close") : L10n.get("history_open"))
        historyButton.accessibilityIdentifier = "HistoryButton"
        tintButton(button: historyButton, lightFill: "#EEF2F7", lightStroke: "#A7B3C4", lightText: "#314154", darkFill: "#263142", darkStroke: "#4B5E76", darkText: "#EFF5FF")
        historyButton.addTarget(self, action: #selector(toggleHistory), for: .touchUpInside)

        zipButton = miniButton(label: L10n.get("zip"))
        zipButton.accessibilityIdentifier = "ZipButton"
        tintButton(button: zipButton, lightFill: "#FFF4D8", lightStroke: "#E8B84C", lightText: "#71500C", darkFill: "#4B3514", darkStroke: "#8A6425", darkText: "#FFE9B0")
        zipButton.addTarget(self, action: #selector(createZipFromCurrentSelection), for: .touchUpInside)

        let themeButton = miniButton(label: darkMode ? L10n.get("light") : L10n.get("dark"))
        themeButton.accessibilityIdentifier = "ThemeButton"
        tintButton(button: themeButton, lightFill: "#F1F4F8", lightStroke: "#BCC8D6", lightText: "#26384E", darkFill: "#2B3442", darkStroke: "#56657A", darkText: "#F4F7FB")
        themeButton.addTarget(self, action: #selector(toggleDarkModeFromTap), for: .touchUpInside)

        let helpButton = miniButton(label: L10n.get("help"))
        helpButton.accessibilityIdentifier = "HelpButton"
        helpButton.addTarget(self, action: #selector(showHelpDialog), for: .touchUpInside)
        let legalButton = miniButton(label: L10n.get("legal_short"))
        legalButton.accessibilityIdentifier = "LegalButton"
        legalButton.addTarget(self, action: #selector(showLegalDialog), for: .touchUpInside)
        languageButton = miniButton(label: L10n.get("language"))
        languageButton.accessibilityIdentifier = "LanguageButton"
        languageButton.addTarget(self, action: #selector(showLanguageDialog), for: .touchUpInside)

        for button in [helpButton, legalButton, languageButton!] {
            button.constraints.filter { $0.firstAttribute == .height }.forEach { $0.isActive = false }
            button.titleLabel?.font = .systemFont(ofSize: 10)
            button.titleLabel?.numberOfLines = 1
            button.contentEdgeInsets = UIEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
            button.setContentHuggingPriority(.required, for: .horizontal)
            titleRow.addArrangedSubview(button)
        }
#if targetEnvironment(macCatalyst)
        openFolderButton = miniButton(label: L10n.get("drives"))
#else
        openFolderButton = miniButton(label: L10n.get("choose_folder"))
#endif
        openFolderButton.accessibilityIdentifier = "OpenFolderButton"
        tintButton(button: openFolderButton, lightFill: "#EAF7FF", lightStroke: "#70AFD1", lightText: "#164B68", darkFill: "#153747", darkStroke: "#4388A8", darkText: "#E3F6FF")
        openFolderButton.addTarget(self, action: #selector(showComputerLocations), for: .touchUpInside)

        let toolbar = CompactActionToolbar(buttons: [openFolderButton, undoButton, deleteButton, renameButton,
            operationButton, historyButton, zipButton, themeButton])
        toolbar.accessibilityIdentifier = "ActionToolbar"
        topBar.addArrangedSubview(toolbar)
        return topBar
    }

    override var keyCommands: [UIKeyCommand]? {
        // Do not intercept Return, Delete, Cmd-C/V or Space while the user
        // edits a destination path (or a text field in a presented dialog).
        func editingText(in view: UIView) -> Bool {
            if view.isFirstResponder && view is UITextInput { return true }
            return view.subviews.contains { editingText(in: $0) }
        }
        if let window = viewIfLoaded?.window, editingText(in: window) { return super.keyCommands }
        let command: UIKeyModifierFlags = .command
        func key(_ title: String, _ input: String, _ modifiers: UIKeyModifierFlags, _ action: Selector) -> UIKeyCommand {
            let result = UIKeyCommand(
                title: title,
                action: action,
                input: input,
                modifierFlags: modifiers,
                discoverabilityTitle: title
            )
            result.wantsPriorityOverSystemBehavior = true
            return result
        }
        var commands = [
            key(L10n.get("copy"), "c", command, #selector(copySelectionToClipboard)),
            key(L10n.get("cut"), "x", command, #selector(cutSelectionToClipboard)),
            key(L10n.get("paste"), "v", command, #selector(pasteClipboard)),
            key(L10n.get("select_all"), "a", command, #selector(selectAllInActivePane)),
            key(L10n.get("undo"), "z", command, #selector(undoLastOperation)),
            key(L10n.get("refresh"), "r", command, #selector(refreshActivePane)),
            key(L10n.get("new_folder"), "n", [command, .shift], #selector(createFolder)),
            key(L10n.get("toggle_hidden"), ".", [command, .shift], #selector(toggleHiddenFiles)),
            key(L10n.get("delete_button"), UIKeyCommand.inputDelete, [], #selector(confirmDeleteSelection))
        ]
#if targetEnvironment(macCatalyst)
        commands.append(contentsOf: [
            key(L10n.get("open"), "o", command, #selector(openSelectedEntry)),
            key(L10n.get("open"), UIKeyCommand.inputDownArrow, command, #selector(openSelectedEntry)),
            key(L10n.get("preview"), " ", [], #selector(previewSelectedEntry)),
            key(L10n.get("preview"), "y", command, #selector(previewSelectedEntry)),
            key(L10n.get("rename_button"), "\r", [], #selector(showRenameDialog)),
            key(L10n.get("duplicate"), "d", command, #selector(duplicateSelection)),
            key(L10n.get("file_info"), "i", command, #selector(showFileInfo)),
            key(L10n.get("move_to_trash"), UIKeyCommand.inputDelete, command, #selector(moveSelectionToTrash)),
            key(L10n.get("go_to_folder"), "g", [command, .shift], #selector(showGoToFolderDialog)),
            key(L10n.get("connect_to_server"), "k", command, #selector(showConnectToServerDialog)),
            key(L10n.get("back"), "[", command, #selector(navigateBack)),
            key(L10n.get("forward"), "]", command, #selector(navigateForward)),
            key(L10n.get("parent_folder"), UIKeyCommand.inputUpArrow, command, #selector(navigateUp)),
            key(L10n.get("computer_root"), "c", [command, .shift], #selector(openComputerRoot)),
            key(L10n.get("home_folder"), "h", [command, .shift], #selector(openHomeFolder)),
            key(L10n.get("desktop_folder"), "d", [command, .shift], #selector(openDesktopFolder)),
            key(L10n.get("documents_folder"), "o", [command, .shift], #selector(openDocumentsFolder)),
            key(L10n.get("downloads_folder"), "l", [command, .alternate], #selector(openDownloadsFolder)),
            key(L10n.get("switch_pane"), "\t", [], #selector(switchActivePane)),
            key(L10n.get("clear_selection"), "\u{1B}", [], #selector(clearSelection))
        ])
#else
        commands.append(contentsOf: [
            key(L10n.get("open"), "\r", [], #selector(openSelectedEntry)),
            key(L10n.get("preview"), " ", [], #selector(previewSelectedEntry))
        ])
#endif
        return commands
    }

    @objc private func toggleDarkMode(_ sender: UISwitch) {
        self.darkMode = sender.isOn
        UserDefaults.standard.set(darkMode, forKey: "dark_mode")
        rebuildApp(status: darkMode ? L10n.get("dark_mode_active") : L10n.get("light_mode_active"))
    }

    @objc private func toggleDarkModeFromTap() {
        self.darkMode = !self.darkMode
        UserDefaults.standard.set(darkMode, forKey: "dark_mode")
        rebuildApp(status: darkMode ? L10n.get("dark_mode_active") : L10n.get("light_mode_active"))
    }
    
    @objc private func toggleHistory() {
        historyExpanded = !historyExpanded
        historyPanel.isHidden = !historyExpanded
        historyButton.setTitle(historyExpanded ? L10n.get("history_close") : L10n.get("history_open"), for: .normal)
        historyButton.superview?.invalidateIntrinsicContentSize()
        historyButton.superview?.setNeedsLayout()
    }

    private func miniButton(label: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(label, for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 14)
        button.titleLabel?.numberOfLines = 0
        button.titleLabel?.textAlignment = .center
        button.layer.cornerRadius = 8
        button.layer.borderWidth = 1
        button.contentEdgeInsets = UIEdgeInsets(top: 0, left: dp(10), bottom: 0, right: dp(10))
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: dp(44)).isActive = true
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }
    
    private func makeSecondaryPortraitButton(button: UIButton) {
        button.titleLabel?.font = UIFont.systemFont(ofSize: 11)
        button.contentEdgeInsets = UIEdgeInsets(top: 0, left: dp(8), bottom: 0, right: dp(8))
    }
    
    private func makeLandscapeButton(button: UIButton) {
        button.titleLabel?.font = UIFont.systemFont(ofSize: 10)
        button.contentEdgeInsets = UIEdgeInsets(top: 0, left: dp(6), bottom: 0, right: dp(6))
        button.constraints.first(where: { $0.firstAttribute == .height })?.constant = dp(28)
    }

    private func makeLowPriorityButton(button: UIButton) {
        button.titleLabel?.font = UIFont.systemFont(ofSize: 9)
        button.contentEdgeInsets = UIEdgeInsets(top: 0, left: dp(5), bottom: 0, right: dp(5))
        button.constraints.first(where: { $0.firstAttribute == .height })?.constant = dp(26)
    }

    private func tintButton(button: UIButton, lightFill: String, lightStroke: String, lightText: String, darkFill: String, darkStroke: String, darkText: String) {
        let fill = darkMode ? darkFill : lightFill
        let stroke = darkMode ? darkStroke : lightStroke
        let text = darkMode ? darkText : lightText
        
        button.backgroundColor = UIColor(hex: fill)
        button.layer.borderColor = UIColor(hex: stroke).cgColor
        button.setTitleColor(UIColor(hex: text), for: .normal)
    }
}

#if targetEnvironment(macCatalyst)
private extension ViewController {
    func createStorageLocationsBar() -> UIView {
        let container = UIView()
        container.backgroundColor = theme.headerBackground
        container.layer.borderColor = theme.panelBorder.cgColor
        container.layer.borderWidth = 1
        container.layer.cornerRadius = 9
        container.heightAnchor.constraint(equalToConstant: 38).isActive = true

        let title = UILabel()
        title.text = L10n.get("locations")
        title.textColor = theme.secondaryText
        title.font = .boldSystemFont(ofSize: 11)
        title.setContentHuggingPriority(.required, for: .horizontal)

        let scrollView = UIScrollView()
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)
        storageLocationsStack = stack

        let row = UIStackView(arrangedSubviews: [title, scrollView])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])

        reloadStorageLocationsBar()
        return container
    }

    func reloadStorageLocationsBar() {
        guard storageLocationsStack != nil else { return }
        storageLocationsRefreshGeneration += 1
        let generation = storageLocationsRefreshGeneration
        renderStorageLocationsBar(discoveredLocations: [])

        DispatchQueue.global(qos: .utility).async {
            let discoveredLocations = HostFileSystem.availableStorageLocations()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.storageLocationsRefreshGeneration == generation else { return }
                self.renderStorageLocationsBar(discoveredLocations: discoveredLocations)
            }
        }
    }

    func renderStorageLocationsBar(discoveredLocations: [HostFileSystem.StorageLocation]) {
        guard let stack = storageLocationsStack else { return }
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        var locations: [(name: String, url: URL, category: String)] = [
            (L10n.get("mac_location"), URL(fileURLWithPath: "/", isDirectory: true), L10n.get("mac_location")),
            (L10n.get("home_folder"), HostFileSystem.homeDirectory, L10n.get("home_folder")),
            (L10n.get("downloads_folder"), HostFileSystem.downloadsDirectory, L10n.get("downloads_folder"))
        ]
        for location in discoveredLocations {
            let category: String
            switch location.kind {
            case .externalDrive: category = L10n.get("external_drive")
            case .networkShare: category = L10n.get("network_share")
            case .cloudStorage: category = L10n.get("cloud_storage")
            }
            locations.append((location.name, location.url, category))
        }

        var addedPaths = Set<String>()
        for location in locations where addedPaths.insert(location.url.standardizedFileURL.path).inserted {
            let button = UIButton(type: .system)
            button.setTitle(location.name, for: .normal)
            button.setTitleColor(theme.primaryText, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 11, weight: .medium)
            button.backgroundColor = theme.buttonBackground
            button.layer.borderColor = theme.pathBorder.cgColor
            button.layer.borderWidth = 1
            button.layer.cornerRadius = 6
            button.contentEdgeInsets = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
            button.accessibilityLabel = "\(location.category): \(location.name)"
            button.accessibilityIdentifier = "Location-\(location.url.standardizedFileURL.path)"
            button.addAction(UIAction { [weak self] _ in
                guard let self, let pane = self.activePane ?? self.leftPane else { return }
                self.openLocation(location.url, in: pane)
            }, for: .touchUpInside)
            stack.addArrangedSubview(button)
        }
    }
}
#endif

extension UIColor {
    convenience init(hex: String) {
        var cString:String = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if (cString.hasPrefix("#")) {
            cString.remove(at: cString.startIndex)
        }
        var rgbValue:UInt64 = 0
        Scanner(string: cString).scanHexInt64(&rgbValue)
        self.init(
            red: CGFloat((rgbValue & 0xFF0000) >> 16) / 255.0,
            green: CGFloat((rgbValue & 0x00FF00) >> 8) / 255.0,
            blue: CGFloat(rgbValue & 0x0000FF) / 255.0,
            alpha: CGFloat(1.0)
        )
    }
}
import UIKit
import ZIPFoundation

extension ViewController {

    func openExternal(_ entry: FileEntry) {
        do {
            let url = try entry.materializedURLForOpening()
            let controller = UIDocumentInteractionController(url: url)
            controller.delegate = self
            documentInteractionController = controller
            if !controller.presentPreview(animated: true) {
                controller.presentOptionsMenu(from: view.bounds, in: view, animated: true)
            }
            updateGlobalStatus(L10n.get("ready"))
        } catch {
            updateGlobalStatus(L10n.get("cannot_open_file"))
        }
    }

    func maybeShowFirstRunHelp() {
#if targetEnvironment(macCatalyst)
        let fullDiskKey = "mac_full_disk_access_onboarding_shown"
        DispatchQueue.global(qos: .utility).async {
            let status = HostFileSystem.fullDiskAccessStatus()
            DispatchQueue.main.async {
                self.fullDiskAccessStatus = status
                if status == .granted {
                    UserDefaults.standard.set(true, forKey: fullDiskKey)
                    self.maybeShowGeneralFirstRunHelp()
                } else if !UserDefaults.standard.bool(forKey: fullDiskKey) {
                    UserDefaults.standard.set(true, forKey: fullDiskKey)
                    self.showFullDiskAccessOnboarding()
                } else {
                    self.maybeShowGeneralFirstRunHelp()
                }
            }
        }
#else
        maybeShowIOSFileAccessOnboarding()
#endif
    }

    private func maybeShowIOSFileAccessOnboarding() {
        let key = "ios_file_access_onboarding_v2_shown"
        guard !UserDefaults.standard.bool(forKey: key) else {
            maybeShowGeneralFirstRunHelp()
            return
        }
        UserDefaults.standard.set(true, forKey: key)

        let alert = UIAlertController(
            title: L10n.get("storage_title"),
            message: L10n.get("storage_message") + "\n\n" + L10n.get("help_access_ios"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.get("choose_folder"), style: .default) { _ in
            self.folderPickerAppliesToBothPanes = true
            self.presentFolderPicker()
        })
        alert.addAction(UIAlertAction(title: L10n.get("later"), style: .cancel))
        DispatchQueue.main.async { self.present(alert, animated: true) }
    }

    private func maybeShowGeneralFirstRunHelp() {
        let key = "onboarding_shown"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        DispatchQueue.main.async { self.showHelpDialog() }
    }
    
    func selectedPanes() -> [CommanderPane] {
        if let active = activePane, !active.selectedKeys.isEmpty {
            return [active]
        }
        var panes: [CommanderPane] = []
        if !leftPane.selectedKeys.isEmpty { panes.append(leftPane) }
        if !rightPane.selectedKeys.isEmpty { panes.append(rightPane) }
        return panes
    }
    
    func selectedEntriesFromPanes(_ panes: [CommanderPane]) -> [FileEntry] {
        var entries: [FileEntry] = []
        for pane in panes {
            for entry in pane.visibleEntries {
                if pane.selectedKeys.contains(entry.key()) {
                    entries.append(entry)
                }
            }
        }
        return entries
    }
    
    func updateGlobalStatus(_ msg: String) {
        globalStatus.text = msg
    }

    func showProgress(_ message: String, progress: Int) {
        operationInProgress = true
        view.isUserInteractionEnabled = false
        progressText.text = message
        progressBar.isHidden = false
        progressBar.progress = Float(progress) / 100
        updateGlobalStatus(message)
    }

    func updateProgress(progress: Int) {
        progressBar.isHidden = false
        progressBar.progress = Float(max(0, min(100, progress))) / 100
    }

    func finishProgress(_ message: String) {
        operationInProgress = false
        view.isUserInteractionEnabled = true
        progressText.text = nil
        progressBar.progress = 1
        progressBar.isHidden = true
        updateGlobalStatus(message)
    }

    func refreshAllPanes(clearSelectionIn panes: [CommanderPane]) {
        panes.forEach { $0.selectedKeys.removeAll() }
        leftPane.reloadTreeKeepingExpansion()
        rightPane.reloadTreeKeepingExpansion()
        leftPane.refreshFiles()
        rightPane.refreshFiles()
        rebuildHistoryPanel()
    }

    func uniqueURL(in directory: URL, name: String) -> URL {
        let fm = FileManager.default
        let source = name as NSString
        let stem = source.deletingPathExtension
        let ext = source.pathExtension
        var candidate = directory.appendingPathComponent(name)
        var index = 2
        while fm.fileExists(atPath: candidate.path) {
            let candidateName = ext.isEmpty ? "\(stem) (\(index))" : "\(stem) (\(index)).\(ext)"
            candidate = directory.appendingPathComponent(candidateName)
            index += 1
        }
        return candidate
    }

    func operationLabel(_ operation: OperationType) -> String {
        switch operation {
        case .delete(let files): return String(format: L10n.get("delete_label"), files.count)
        case .move(let files): return String(format: L10n.get("move_label"), files.count)
        case .copy(let files): return String(format: L10n.get("copy_label"), files.count)
        case .zip: return String(format: L10n.get("zip_label"), 1)
        case .rename(_, let newURL): return String(format: L10n.get("renamed_item"), newURL.lastPathComponent)
        }
    }
    
    @objc func confirmDeleteSelection() {
        let panes = selectedPanes()
        if panes.isEmpty {
            updateGlobalStatus(L10n.get("no_file_selected"))
            return
        }
        let sources = selectedEntriesFromPanes(panes)
        if sources.isEmpty {
            updateGlobalStatus(L10n.get("no_readable_selection"))
            return
        }
        
        if sources.contains(where: { !$0.isPhysical() }) {
            updateGlobalStatus(L10n.get("zip_read_only"))
            return
        }
        
        let alert = UIAlertController(title: L10n.get("delete_title"), message: String(format: L10n.get("delete_message"), sources.count), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.get("delete_permanent"), style: .destructive, handler: { _ in
            self.executeDeleteOperation(panes: panes, sources: sources, toTrash: false)
        }))
        alert.addAction(UIAlertAction(title: L10n.get("trash"), style: .default, handler: { _ in
            self.executeDeleteOperation(panes: panes, sources: sources, toTrash: true)
        }))
        alert.addAction(UIAlertAction(title: L10n.get("cancel"), style: .cancel, handler: nil))
        self.present(alert, animated: true)
    }
    
    func executeDeleteOperation(panes: [CommanderPane], sources: [FileEntry], toTrash: Bool) {
        showProgress(String(format: L10n.get("deleting_items"), sources.count), progress: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let backupRoot = fm.temporaryDirectory.appendingPathComponent("OpenCommanderUndo-\(UUID().uuidString)", isDirectory: true)
            try? fm.createDirectory(at: backupRoot, withIntermediateDirectories: true)
            var records: [(originalUrl: URL, backupUrl: URL)] = []
            var failure: Error?
            for (index, source) in sources.enumerated() {
                let url = source.url
                do {
                    if toTrash {
#if targetEnvironment(macCatalyst)
                        var resultingURL: NSURL?
                        try fm.trashItem(at: url, resultingItemURL: &resultingURL)
                        guard let trashedURL = resultingURL as URL? else {
                            throw NSError(
                                domain: "OpenCommander",
                                code: 3,
                                userInfo: [NSLocalizedDescriptionKey: String(format: L10n.get("cannot_move_to_trash"), url.lastPathComponent)]
                            )
                        }
                        records.append((url, trashedURL))
#else
                        let parent = url.deletingLastPathComponent()
                        let trashDirectory = parent.appendingPathComponent(".OpenCommanderTrash", isDirectory: true)
                        guard url.standardizedFileURL != trashDirectory.standardizedFileURL,
                              !trashDirectory.standardizedFileURL.path.hasPrefix(url.standardizedFileURL.path + "/") else {
                            throw NSError(
                                domain: "OpenCommander",
                                code: 3,
                                userInfo: [NSLocalizedDescriptionKey: String(format: L10n.get("cannot_move_to_trash"), url.lastPathComponent)]
                            )
                        }
                        try fm.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
                        let trashedURL = self.uniqueURL(in: trashDirectory, name: url.lastPathComponent)
                        try fm.moveItem(at: url, to: trashedURL)
                        records.append((url, trashedURL))
#endif
                    } else {
                        let backup = self.uniqueURL(in: backupRoot, name: url.lastPathComponent)
                        try fm.moveItem(at: url, to: backup)
                        records.append((url, backup))
                    }
                } catch {
                    failure = error
                    break
                }
                let progress = Int((Double(index + 1) / Double(max(1, sources.count))) * 100)
                DispatchQueue.main.async { self.updateProgress(progress: progress) }
            }
            DispatchQueue.main.async {
                if !records.isEmpty { self.operationHistory.append(.delete(files: records)) }
                self.refreshAllPanes(clearSelectionIn: panes)
                if let failure {
                    self.finishProgress(L10n.get("error_prefix").replacingOccurrences(of: "%@", with: failure.localizedDescription))
                } else {
                    let key = toTrash ? "trashed_items" : "deleted_items"
                    self.finishProgress(String(format: L10n.get(key), records.count))
                }
            }
        }
    }
    
    @objc func showRenameDialog() {
        let panes = selectedPanes()
        let sources = selectedEntriesFromPanes(panes)
        if sources.count != 1 {
            updateGlobalStatus(L10n.get("rename_single_selection"))
            return
        }
        
        let source = sources[0]
        guard source.isPhysical() else {
            updateGlobalStatus(L10n.get("zip_read_only"))
            return
        }
        
        let alert = UIAlertController(title: L10n.get("rename_title"), message: nil, preferredStyle: .alert)
        alert.addTextField { textField in
            textField.text = source.name()
        }
        alert.addAction(UIAlertAction(title: L10n.get("rename_title"), style: .default, handler: { [weak alert] _ in
            guard let newName = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  self.isValidFileName(newName) else {
                self.updateGlobalStatus(L10n.get("rename_invalid_name"))
                return
            }
            self.startRename(source: source, newName: newName, panes: panes)
        }))
        alert.addAction(UIAlertAction(title: L10n.get("cancel"), style: .cancel, handler: nil))
        self.present(alert, animated: true)
    }
    
    func startRename(source: FileEntry, newName: String, panes: [CommanderPane]) {
        let url = source.url
        let newUrl = url.deletingLastPathComponent().appendingPathComponent(newName)
        guard !FileManager.default.fileExists(atPath: newUrl.path) else {
            updateGlobalStatus(L10n.get("rename_failed"))
            return
        }
        
        showProgress(L10n.get("rename_title"), progress: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            do {
                try fm.moveItem(at: url, to: newUrl)
                DispatchQueue.main.async {
                    self.operationHistory.append(.rename(originalUrl: url, newUrl: newUrl))
                    self.refreshAllPanes(clearSelectionIn: panes)
                    self.finishProgress(String(format: L10n.get("renamed_item"), newName))
                }
            } catch {
                DispatchQueue.main.async {
                    self.finishProgress(L10n.get("rename_failed"))
                }
            }
        }
    }

    private func isValidFileName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains(":") && !name.contains("\0")
    }
}

extension ViewController {
    func runFileOperation(sourcePane: CommanderPane, targetDirectory: FileEntry) {
        if sourcePane.selectedKeys.isEmpty {
            updateGlobalStatus(L10n.get("no_file_selected"))
            return
        }
        
        runFileOperation(sources: sourcePane.selectedEntries(), sourcePane: sourcePane,
                         targetDirectory: targetDirectory, move: moveMode)
    }

    func receiveExternalDrop(providers: [NSItemProvider], targetDirectory: FileEntry) {
        guard !externalDropInProgress, !fileOperationInProgress, presentedViewController == nil,
              targetDirectory.canWriteDirectory() else { return }
        externalDropInProgress = true
        let requestedMove = moveMode
        updateGlobalStatus(L10n.get("drop_loading"))
        FileDropTransfer.load(providers) { [weak self] result in
            guard let self else {
                if case .success(let batch) = result { batch.releaseResources() }
                return
            }
            switch result {
            case .failure(let error):
                self.externalDropInProgress = false
                self.updateGlobalStatus(String(format: L10n.get("error_prefix"), error.localizedDescription))
            case .success(let batch):
                if requestedMove && batch.items.contains(where: { !$0.isOriginal }) {
                    batch.releaseResources()
                    self.externalDropInProgress = false
                    self.showScrollableDialog(title: L10n.get("operation_mode_move"), message: L10n.get("drop_original_unavailable"))
                    return
                }
                self.runFileOperation(sources: batch.items.map { FileEntry(url: $0.url, parent: nil) },
                                      sourcePane: nil, targetDirectory: targetDirectory, move: requestedMove) {
                    // Retain provider resources through conflict prompts and I/O.
                    batch.releaseResources()
                    self.externalDropInProgress = false
                }
            }
        }
    }

    func runFileOperation(sources: [FileEntry], sourcePane: CommanderPane?, targetDirectory: FileEntry,
                          move: Bool, completion: @escaping () -> Void = {}) {
        guard !fileOperationInProgress, presentedViewController == nil else {
            updateGlobalStatus(L10n.get("drop_busy"))
            completion()
            return
        }
        if sources.isEmpty {
            updateGlobalStatus(L10n.get("no_readable_selection"))
            completion()
            return
        }
        guard targetDirectory.canWriteDirectory() else {
            updateGlobalStatus(L10n.get("target_not_writable"))
            completion()
            return
        }
        guard sources.allSatisfy({ $0.isPhysical() }) else {
            updateGlobalStatus(L10n.get("zip_read_only"))
            completion()
            return
        }

        fileOperationInProgress = true
        let finished = {
            self.fileOperationInProgress = false
            completion()
        }
        let conflicts = sources.filter {
            let destination = targetDirectory.url.appendingPathComponent($0.name())
            return destination.standardizedFileURL != $0.url.standardizedFileURL && FileManager.default.fileExists(atPath: destination.path)
        }
        if !conflicts.isEmpty {
            let alert = UIAlertController(
                title: L10n.get("target_exists_title"),
                message: String(format: L10n.get("target_exists_message"), conflicts.count),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: L10n.get("replace"), style: .destructive) { _ in
                self.executeFileOperation(sourcePane: sourcePane, targetDirectory: targetDirectory, sources: sources, move: move, replace: true, completion: finished)
            })
            alert.addAction(UIAlertAction(title: L10n.get("keep"), style: .default) { _ in
                self.executeFileOperation(sourcePane: sourcePane, targetDirectory: targetDirectory, sources: sources, move: move, replace: false, completion: finished)
            })
            alert.addAction(UIAlertAction(title: L10n.get("cancel"), style: .cancel) { _ in finished() })
            present(alert, animated: true)
            return
        }
        executeFileOperation(sourcePane: sourcePane, targetDirectory: targetDirectory, sources: sources, move: move, replace: false, completion: finished)
    }

    private func executeFileOperation(sourcePane: CommanderPane?, targetDirectory: FileEntry, sources: [FileEntry], move: Bool, replace: Bool, completion: @escaping () -> Void) {
        showProgress(String(format: L10n.get(move ? "moving_items" : "copying_items"), sources.count), progress: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let targetURL = targetDirectory.url
            let backupRoot = fm.temporaryDirectory.appendingPathComponent("OpenCommanderUndo-\(UUID().uuidString)", isDirectory: true)
            try? fm.createDirectory(at: backupRoot, withIntermediateDirectories: true)
            var movedFiles: [(source: URL, destination: URL, replacedBackup: URL?)] = []
            var copiedFiles: [(source: URL, destination: URL, replacedBackup: URL?)] = []
            var failure: Error?

            for (index, source) in sources.enumerated() {
                let sourceURL = source.url
                let preferred = targetURL.appendingPathComponent(sourceURL.lastPathComponent)
                if sourceURL.standardizedFileURL == preferred.standardizedFileURL { continue }
                let sourcePath = sourceURL.resolvingSymlinksInPath().path
                let targetPath = targetURL.resolvingSymlinksInPath().path
                if source.isPhysicalDirectory() && (targetPath == sourcePath || targetPath.hasPrefix(sourcePath + "/")) {
                    failure = NSError(domain: "OpenCommander", code: 1, userInfo: [NSLocalizedDescriptionKey: String(format: L10n.get("cannot_copy_into_self"), source.name())])
                    break
                }
                var destination = preferred
                var replacedBackup: URL?
                do {
                    if fm.fileExists(atPath: preferred.path) {
                        if replace {
                            let backup = self.uniqueURL(in: backupRoot, name: preferred.lastPathComponent)
                            try fm.moveItem(at: preferred, to: backup)
                            replacedBackup = backup
                        } else {
                            destination = self.uniqueURL(in: targetURL, name: preferred.lastPathComponent)
                        }
                    }
                    if move {
                        try fm.moveItem(at: sourceURL, to: destination)
                        movedFiles.append((sourceURL, destination, replacedBackup))
                    } else {
                        try fm.copyItem(at: sourceURL, to: destination)
                        copiedFiles.append((sourceURL, destination, replacedBackup))
                    }
                } catch {
                    failure = error
                    if let replacedBackup, !fm.fileExists(atPath: preferred.path) {
                        try? fm.moveItem(at: replacedBackup, to: preferred)
                    }
                    break
                }
                let progress = Int((Double(index + 1) / Double(max(1, sources.count))) * 100)
                DispatchQueue.main.async { self.updateProgress(progress: progress) }
            }

            DispatchQueue.main.async {
                if move && !movedFiles.isEmpty { self.operationHistory.append(.move(files: movedFiles)) }
                if !move && !copiedFiles.isEmpty { self.operationHistory.append(.copy(files: copiedFiles)) }
                self.refreshAllPanes(clearSelectionIn: sourcePane.map { [$0] } ?? [])
                if let failure {
                    self.finishProgress(String(format: L10n.get("error_prefix"), failure.localizedDescription))
                } else {
                    let count = move ? movedFiles.count : copiedFiles.count
                    self.finishProgress(String(format: L10n.get(move ? "moved_items" : "copied_items"), count))
                }
                completion()
            }
        }
    }
}

extension ViewController {
    @objc func toggleOperationMode(_ sender: UIButton) {
        moveMode.toggle()
        let title = L10n.get(moveMode ? "operation_mode_move" : "operation_mode_copy")
        sender.setTitle(title, for: .normal)
        sender.isSelected = moveMode
        sender.accessibilityValue = title
        if moveMode {
            sender.accessibilityTraits.insert(.selected)
        } else {
            sender.accessibilityTraits.remove(.selected)
        }
        sender.superview?.invalidateIntrinsicContentSize()
        sender.superview?.setNeedsLayout()
        updateGlobalStatus(L10n.get(moveMode ? "operation_mode_move_active" : "operation_mode_copy_active"))
    }
}

extension ViewController {
    private func archiveName(for sources: [FileEntry]) -> String {
        let base: String
        if sources.count == 1 {
            let source = sources[0]
            base = source.isPhysicalDirectory()
                ? source.name()
                : (source.name() as NSString).deletingPathExtension
        } else {
            base = sources[0].url.deletingLastPathComponent().lastPathComponent
        }
        return (base.isEmpty ? "Archive" : base) + ".zip"
    }

    @objc func createZipFromCurrentSelection() {
        // ZIP uses one pane, matching Android; selections in the other pane
        // must not unexpectedly add unrelated files to the archive.
        let pane = [activePane, leftPane, rightPane].compactMap { $0 }
            .first { !$0.selectedKeys.isEmpty }
        let panes = pane.map { [$0] } ?? []
        let sources = pane?.selectedEntries() ?? []
        if sources.isEmpty {
            updateGlobalStatus(L10n.get("zip_no_selection"))
            return
        }
        guard sources.allSatisfy({ $0.isPhysical() }) else {
            updateGlobalStatus(L10n.get("zip_read_only"))
            return
        }
        showProgress(String(format: L10n.get("zip_creating"), sources.count), progress: 0)
        
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let parentDir = sources.first!.url.deletingLastPathComponent()
            let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let stagingDirectory = fm.temporaryDirectory.appendingPathComponent("OpenCommanderZIP-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: stagingDirectory) }

            do {
                // Snapshot input names before creating any output. In particular,
                // zipping Documents into Documents must never include the new ZIP.
                var entries: [(path: String, url: URL)] = []
                var pending = sources.map { (path: $0.name(), url: $0.url) }
                while let entry = pending.popLast() {
                    entries.append(entry)
                    let values = try entry.url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    if values.isDirectory == true && values.isSymbolicLink != true {
                        let children = try fm.contentsOfDirectory(at: entry.url,
                            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                        for child in children {
                            // Build archive paths from names, never by subtracting
                            // /var vs /private/var filesystem URL prefixes.
                            pending.append((entry.path + "/" + child.lastPathComponent, child))
                        }
                    }
                }
                try fm.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
                let stagedArchive = stagingDirectory.appendingPathComponent("archive.zip")
                try autoreleasepool {
                    let archive = try Archive(url: stagedArchive, accessMode: .create, pathEncoding: nil)
                    for (index, entry) in entries.enumerated() {
                        // Keep the actual source URL separate from the ZIP entry name.
                        try archive.addEntry(with: entry.path, fileURL: entry.url)
                        let progress = Int(Double(index + 1) / Double(entries.count) * 100)
                        DispatchQueue.main.async { self.updateProgress(progress: progress) }
                    }
                }
                func publish(in directory: URL) throws -> URL {
                    let destination = self.uniqueURL(in: directory, name: self.archiveName(for: sources))
                    try fm.moveItem(at: stagedArchive, to: destination)
                    return destination
                }
                func isWritePermissionError(_ error: NSError) -> Bool {
                    if error.domain == NSCocoaErrorDomain &&
                        [CocoaError.Code.fileWriteNoPermission.rawValue, CocoaError.Code.fileWriteVolumeReadOnly.rawValue].contains(error.code) {
                        return true
                    }
                    if error.domain == NSPOSIXErrorDomain && [1, 13, 30].contains(error.code) { return true }
                    return (error.userInfo[NSUnderlyingErrorKey] as? NSError).map(isWritePermissionError) ?? false
                }
                let archiveURL: URL
                let usedDocuments: Bool
                do {
                    archiveURL = try publish(in: parentDir)
                    usedDocuments = false
                } catch {
                    guard isWritePermissionError(error as NSError),
                          parentDir.resolvingSymlinksInPath() != documents.resolvingSymlinksInPath() else { throw error }
                    // iOS forbids creating Documents.zip beside Documents at the
                    // container root. Publish it inside the writable Documents folder.
                    archiveURL = try publish(in: documents)
                    usedDocuments = true
                }
                DispatchQueue.main.async {
                    self.operationHistory.append(.zip(url: archiveURL))
                    if usedDocuments { pane?.openDirectory(FileEntry(url: documents, parent: nil)) }
                    self.refreshAllPanes(clearSelectionIn: panes)
                    let location = usedDocuments ? "/Documents/" + archiveURL.lastPathComponent : archiveURL.lastPathComponent
                    self.finishProgress(String(format: L10n.get("zip_created"), location))
                }
            } catch {
                DispatchQueue.main.async {
                    self.finishProgress(String(format: L10n.get("zip_failed"), error.localizedDescription))
                }
            }
        }
    }
    
    @objc func undoLastOperation() {
        undoOperation(at: operationHistory.count - 1)
    }

    private func undoOperation(at index: Int) {
        guard !operationInProgress else { return }
        guard operationHistory.indices.contains(index) else {
            updateGlobalStatus(L10n.get("undo_empty"))
            return
        }
        let lastOp = operationHistory[index]
        showProgress(String(format: L10n.get("undo_progress"), operationLabel(lastOp)), progress: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            do {
                switch lastOp {
                case .delete(let files):
                    for file in files {
                        try fm.moveItem(at: file.backupUrl, to: file.originalUrl)
                    }
                case .move(let files):
                    for file in files.reversed() {
                        try fm.moveItem(at: file.destination, to: file.source)
                        if let backup = file.replacedBackup { try fm.moveItem(at: backup, to: file.destination) }
                    }
                case .copy(let files):
                    for file in files.reversed() {
                        try fm.removeItem(at: file.destination)
                        if let backup = file.replacedBackup { try fm.moveItem(at: backup, to: file.destination) }
                    }
                case .zip(let url):
                    try fm.removeItem(at: url)
                case .rename(let originalUrl, let newUrl):
                    try fm.moveItem(at: newUrl, to: originalUrl)
                }
                
                DispatchQueue.main.async {
                    self.operationHistory.remove(at: index)
                    self.refreshAllPanes(clearSelectionIn: [])
                    self.finishProgress(String(format: L10n.get("undo_done"), 1))
                }
            } catch {
                DispatchQueue.main.async {
                    self.finishProgress(String(format: L10n.get("undo_failed"), error.localizedDescription))
                }
            }
        }
    }
}

extension ViewController {
    
    func showScrollableDialog(title: String, message: String) {
        let vc = UIViewController()
        vc.view.backgroundColor = theme.appBackground
        
        let navBar = UINavigationBar()
        navBar.translatesAutoresizingMaskIntoConstraints = false
        navBar.barTintColor = theme.columnHeaderBackground
        navBar.titleTextAttributes = [.foregroundColor: theme.primaryText]
        let navItem = UINavigationItem(title: title)
        navItem.rightBarButtonItem = UIBarButtonItem(title: L10n.get("ok"), style: .done, target: self, action: #selector(dismissModal))
        navBar.items = [navItem]
        
        let textView = UITextView()
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.text = message
        textView.font = UIFont.systemFont(ofSize: 13)
        textView.isEditable = false
        textView.backgroundColor = .clear
        textView.textColor = theme.primaryText
        
        vc.view.addSubview(navBar)
        vc.view.addSubview(textView)
        
        NSLayoutConstraint.activate([
            navBar.topAnchor.constraint(equalTo: vc.view.topAnchor),
            navBar.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
            navBar.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),
            
            textView.topAnchor.constraint(equalTo: navBar.bottomAnchor, constant: 8),
            textView.bottomAnchor.constraint(equalTo: vc.view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            textView.leadingAnchor.constraint(equalTo: vc.view.safeAreaLayoutGuide.leadingAnchor, constant: 15),
            textView.trailingAnchor.constraint(equalTo: vc.view.safeAreaLayoutGuide.trailingAnchor, constant: -15)
        ])
        
        self.present(vc, animated: true)
    }
    
    @objc func dismissModal() {
        self.presentedViewController?.dismiss(animated: true)
    }

    @objc func showLegalDialog() {
        showScrollableDialog(title: L10n.get("legal_title"), message: L10n.get("legal_message_full_clean"))
    }
    
    @objc func showHelpDialog() {
        var sections = [L10n.get("help_message")]
        sections.append(L10n.get("help_external_drop"))
#if targetEnvironment(macCatalyst)
        sections.append(L10n.get("help_access_macos"))
        sections.append(macKeyboardShortcutsHelp())
#else
        sections.append(L10n.get("help_access_ios"))
#endif
        showScrollableDialog(
            title: L10n.get("help_title"),
            message: sections.joined(separator: "\n\n")
        )
    }

#if targetEnvironment(macCatalyst)
    private func macKeyboardShortcutsHelp() -> String {
        [
            L10n.get("keyboard_shortcuts"),
            "⌘C — \(L10n.get("copy"))    ⌘X — \(L10n.get("cut"))    ⌘V — \(L10n.get("paste"))",
            "⌘A — \(L10n.get("select_all"))    ⌘Z — \(L10n.get("undo"))",
            "⌘O / ⌘↓ — \(L10n.get("open"))    \(L10n.get("space_key")) / ⌘Y — \(L10n.get("preview"))",
            "Return — \(L10n.get("rename_button"))    ⌘D — \(L10n.get("duplicate"))",
            "⌘I — \(L10n.get("file_info"))    ⌘⌫ — \(L10n.get("move_to_trash"))",
            "⌘[ / ⌘] — \(L10n.get("back")) / \(L10n.get("forward"))    ⌘↑ — \(L10n.get("parent_folder"))",
            "⇧⌘G — \(L10n.get("go_to_folder"))    ⌘K — \(L10n.get("connect_to_server"))",
            "⇧⌘N — \(L10n.get("new_folder"))",
            "⇧⌘C — /    ⇧⌘H — \(L10n.get("home_folder"))    ⇧⌘D — \(L10n.get("desktop_folder"))",
            "⇧⌘O — \(L10n.get("documents_folder"))    ⌥⌘L — \(L10n.get("downloads_folder"))",
            "⇧⌘. — \(L10n.get("toggle_hidden"))    Tab — \(L10n.get("switch_pane"))"
        ].joined(separator: "\n")
    }
#endif
    
    @objc func showLanguageDialog() {
        let alert = UIAlertController(title: L10n.get("language"), message: nil, preferredStyle: .actionSheet)
        let languages = [
            (L10n.get("language_system"), ""),
            ("Deutsch", "de"),
            ("English", "en"),
            ("Français", "fr"),
            ("Español", "es"),
            ("Italiano", "it"),
            ("Português", "pt"),
            ("Nederlands", "nl"),
            ("简体中文", "zh-Hans"),
            ("日本語", "ja"),
            ("한국어", "ko"),
            ("العربية", "ar"),
            ("हिन्दी", "hi"),
            ("Русский", "ru"),
            ("Türkçe", "tr"),
            ("Polski", "pl"),
            ("Bahasa Indonesia", "id"),
            ("Tiếng Việt", "vi"),
            ("ไทย", "th"),
            ("Українська", "uk"),
            ("Svenska", "sv")
        ]
        for lang in languages {
            alert.addAction(UIAlertAction(title: lang.0, style: .default, handler: { _ in
                L10n.currentLanguage = L10n.resolvedLanguage(lang.1 == "" ? Locale.current.identifier : lang.1)
                UserDefaults.standard.set(lang.1, forKey: "language")
                self.rebuildApp()
            }))
        }
        alert.addAction(UIAlertAction(title: L10n.get("cancel"), style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = self.languageButton
            popover.sourceRect = self.languageButton.bounds
        }
        self.present(alert, animated: true)
    }

    func rebuildApp(status: String = L10n.get("language_changed")) {
        let currentDirLeft = leftPane.currentDirectory
        let currentDirRight = rightPane.currentDirectory
        
        for view in view.subviews {
            view.removeFromSuperview()
        }
        buildLayout()
        
        if let dirLeft = currentDirLeft { leftPane.openDirectory(dirLeft) }
        if let dirRight = currentDirRight { rightPane.openDirectory(dirRight) }
        updateGlobalStatus(status)
    }

    func rebuildHistoryPanel() {
        historyPanel.subviews.forEach { $0.removeFromSuperview() }
        historyPanel.constraints.filter { $0.firstAttribute == .height }.forEach { $0.isActive = false }
        let scroll = UIScrollView()
        scroll.accessibilityIdentifier = "HistoryList"
        scroll.translatesAutoresizingMaskIntoConstraints = false
        historyPanel.addSubview(scroll)
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: historyPanel.topAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: historyPanel.bottomAnchor, constant: -4),
            scroll.leadingAnchor.constraint(equalTo: historyPanel.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: historyPanel.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
        ])
        // The history scrolls independently and never pushes both file panes away.
        let height = historyPanel.heightAnchor.constraint(equalToConstant: operationHistory.isEmpty ? 28 : 60)
        height.priority = .defaultHigh
        height.isActive = true
        if operationHistory.isEmpty {
            let label = UILabel()
            label.text = L10n.get("history_empty")
            label.textColor = theme.secondaryText
            label.font = UIFont.systemFont(ofSize: 12)
            stack.addArrangedSubview(label)
        } else {
            for index in operationHistory.indices.reversed() {
                let op = operationHistory[index]
                let title: String
                switch op {
                case .delete(let files): title = String(format: L10n.get("deleted_items"), files.count)
                case .move(let files): title = String(format: L10n.get("moved_items"), files.count)
                case .copy(let files): title = String(format: L10n.get("copied_items"), files.count)
                case .zip(let url): title = String(format: L10n.get("zip_created"), url.lastPathComponent)
                case .rename(_, let newUrl): title = String(format: L10n.get("renamed_item"), newUrl.lastPathComponent)
                }
                let item = miniButton(label: title)
                item.accessibilityIdentifier = "HistoryEntry-\(index)"
                item.contentHorizontalAlignment = .leading
                item.setTitleColor(theme.primaryText, for: .normal)
                item.addAction(UIAction { [weak self] _ in self?.undoOperation(at: index) }, for: .touchUpInside)
                stack.addArrangedSubview(item)
            }
        }
    }

}

extension ViewController: UIDocumentInteractionControllerDelegate {
    func documentInteractionControllerViewControllerForPreview(_ controller: UIDocumentInteractionController) -> UIViewController {
        self
    }
}

// MARK: - Desktop file access and keyboard workflow

extension ViewController: UIDocumentPickerDelegate {
    @objc func showComputerLocations() {
#if targetEnvironment(macCatalyst)
        let alert = UIAlertController(title: L10n.get("computer_locations"), message: nil, preferredStyle: .actionSheet)
        var locations: [(String, URL)] = [
            (L10n.get("computer_root"), URL(fileURLWithPath: "/", isDirectory: true)),
            (L10n.get("home_folder"), HostFileSystem.homeDirectory)
        ]
        locations.append((L10n.get("downloads_folder"), HostFileSystem.downloadsDirectory))
        locations.append((L10n.get("desktop_folder"), HostFileSystem.desktopDirectory))
        for location in HostFileSystem.availableStorageLocations() {
            let prefix: String
            switch location.kind {
            case .externalDrive: prefix = L10n.get("external_drive")
            case .networkShare: prefix = L10n.get("network_share")
            case .cloudStorage: prefix = L10n.get("cloud_storage")
            }
            locations.append(("\(prefix): \(location.name)", location.url))
        }
        var addedPaths = Set<String>()
        for (title, url) in locations where addedPaths.insert(url.standardizedFileURL.path).inserted {
            alert.addAction(UIAlertAction(title: title, style: .default) { _ in
                self.openLocation(url, in: self.activePane ?? self.leftPane)
            })
        }
        let fullDiskTitle = fullDiskAccessStatus == .granted
            ? L10n.get("full_disk_access_active")
            : L10n.get("full_disk_access")
        alert.addAction(UIAlertAction(title: fullDiskTitle, style: .default) { _ in
            if self.fullDiskAccessStatus == .granted {
                self.refreshFullDiskAccessStatus(showFeedback: true)
            } else {
                self.showFullDiskAccessOnboarding()
            }
        })
        alert.addAction(UIAlertAction(title: L10n.get("ntfs_extension_settings"), style: .default) { _ in
            self.showNTFSExtensionOnboarding()
        })
        alert.addAction(UIAlertAction(title: L10n.get("connect_to_server"), style: .default) { _ in
            self.showConnectToServerDialog()
        })
        alert.addAction(UIAlertAction(title: L10n.get("choose_other_folder"), style: .default) { _ in
            self.presentFolderPicker()
        })
        alert.addAction(UIAlertAction(title: L10n.get("cancel"), style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = openFolderButton ?? view
            popover.sourceRect = (openFolderButton ?? view).bounds
        }
        present(alert, animated: true)
#else
        presentFolderPicker()
#endif
    }

#if targetEnvironment(macCatalyst)
    @objc private func showConnectToServerDialog() {
        let alert = UIAlertController(
            title: L10n.get("connect_to_server"),
            message: L10n.get("server_address_prompt"),
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = "smb://server/share"
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
            field.keyboardType = .URL
        }
        alert.addAction(UIAlertAction(title: L10n.get("connect"), style: .default) { [weak alert] _ in
            guard var address = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !address.isEmpty else { return }
            if !address.contains("://") { address = "smb://" + address }
            guard let url = URL(string: address),
                  ["smb", "afp", "nfs"].contains(url.scheme?.lowercased() ?? "") else {
                self.updateGlobalStatus(L10n.get("invalid_server_address"))
                return
            }
            UIApplication.shared.open(url, options: [:]) { opened in
                self.updateGlobalStatus(L10n.get(opened ? "server_connection_opened" : "server_connection_failed"))
            }
        })
        alert.addAction(UIAlertAction(title: L10n.get("cancel"), style: .cancel))
        present(alert, animated: true)
    }

    private func showFullDiskAccessOnboarding() {
        let alert = UIAlertController(
            title: L10n.get("full_disk_access_title"),
            message: L10n.get("full_disk_access_message"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.get("open_system_settings"), style: .default) { _ in
            self.openSystemSettings(
                "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
                status: L10n.get("full_disk_access_opened")
            )
        })
        alert.addAction(UIAlertAction(title: L10n.get("check_access"), style: .default) { _ in
            self.refreshFullDiskAccessStatus(showFeedback: true)
        })
        alert.addAction(UIAlertAction(title: L10n.get("later"), style: .cancel))
        present(alert, animated: true)
    }

    private func refreshFullDiskAccessStatus(showFeedback: Bool) {
        DispatchQueue.global(qos: .utility).async {
            let status = HostFileSystem.fullDiskAccessStatus()
            DispatchQueue.main.async {
                self.fullDiskAccessStatus = status
                if status == .granted {
                    UserDefaults.standard.set(true, forKey: "mac_full_disk_access_onboarding_shown")
                    self.leftPane?.refreshFiles()
                    self.rightPane?.refreshFiles()
                }
                guard showFeedback else { return }
                switch status {
                case .granted:
                    self.updateGlobalStatus(L10n.get("full_disk_access_granted"))
                case .denied:
                    self.updateGlobalStatus(L10n.get("full_disk_access_denied"))
                case .unavailable:
                    self.updateGlobalStatus(L10n.get("full_disk_access_unavailable"))
                }
            }
        }
    }

    private func showNTFSExtensionOnboarding() {
        let alert = UIAlertController(
            title: L10n.get("ntfs_extension_title"),
            message: L10n.get("ntfs_extension_message"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.get("open_system_settings"), style: .default) { _ in
            self.openSystemSettings("x-apple.systempreferences:com.apple.LoginItems-Settings.extension", status: nil)
        })
        alert.addAction(UIAlertAction(title: L10n.get("later"), style: .cancel))
        present(alert, animated: true)
    }

    private func openSystemSettings(_ value: String, status: String?) {
        guard let url = URL(string: value) else { return }
        UIApplication.shared.open(url, options: [:]) { opened in
            if opened, let status { self.updateGlobalStatus(status) }
        }
    }
#endif

    private func presentFolderPicker() {
        folderPickerPane = activePane ?? leftPane
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first, let pane = folderPickerPane ?? activePane else { return }
        _ = url.startAccessingSecurityScopedResource()
        securityScopedURLs.append(url)
        if folderPickerAppliesToBothPanes {
            folderPickerAppliesToBothPanes = false
            for targetPane in [leftPane, rightPane].compactMap({ $0 }) {
                saveFolderBookmark(url, forPane: targetPane.title)
                openLocation(url, in: targetPane, persistPath: false)
            }
        } else {
            saveFolderBookmark(url, forPane: pane.title)
            openLocation(url, in: pane, persistPath: false)
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        folderPickerAppliesToBothPanes = false
    }

    private func openLocation(_ url: URL, in pane: CommanderPane, persistPath: Bool = true) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            updateGlobalStatus(L10n.get("path_not_found"))
            return
        }
        if persistPath {
            UserDefaults.standard.set(url.path, forKey: pathKey(forPane: pane.title))
            UserDefaults.standard.removeObject(forKey: bookmarkKey(forPane: pane.title))
        }
        pane.setRoot(FileEntry(url: url, parent: nil))
        pane.rebuildTree()
        pane.refreshFiles()
        activePane = pane
        updateGlobalStatus(volumeStatus(for: url))
    }

    private func pathKey(forPane title: String) -> String {
        "folder_path_pane_\(title)"
    }

    private func bookmarkKey(forPane title: String) -> String {
        "folder_bookmark_pane_\(title)"
    }

    private func saveFolderBookmark(_ url: URL, forPane title: String) {
#if targetEnvironment(macCatalyst)
        UserDefaults.standard.set(url.path, forKey: pathKey(forPane: title))
        do {
            let data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: bookmarkKey(forPane: title))
        } catch {
            // Unsandboxed Developer ID builds can still restore the raw path. App Sandbox
            // builds need the security-scoped bookmark and will fail closed if it is absent.
        }
#else
        do {
            let data = try url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: bookmarkKey(forPane: title))
        } catch {
            updateGlobalStatus(String(format: L10n.get("error_prefix"), error.localizedDescription))
        }
#endif
    }

    private func restoreFolderLocation(forPane title: String) -> URL? {
#if targetEnvironment(macCatalyst)
        if let data = UserDefaults.standard.data(forKey: bookmarkKey(forPane: title)) {
            do {
                var stale = false
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                )
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                if url.startAccessingSecurityScopedResource() {
                    securityScopedURLs.append(url)
                }
                if stale { saveFolderBookmark(url, forPane: title) }
                return url
            } catch {
                UserDefaults.standard.removeObject(forKey: bookmarkKey(forPane: title))
            }
        }
        if let path = UserDefaults.standard.string(forKey: pathKey(forPane: title)) {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return nil
#else
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey(forPane: title)) else { return nil }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            _ = url.startAccessingSecurityScopedResource()
            securityScopedURLs.append(url)
            if stale { saveFolderBookmark(url, forPane: title) }
            return url
        } catch {
            UserDefaults.standard.removeObject(forKey: bookmarkKey(forPane: title))
            return nil
        }
#endif
    }

    private func volumeStatus(for url: URL) -> String {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeLocalizedFormatDescriptionKey, .volumeIsReadOnlyKey]
        let values = try? url.resourceValues(forKeys: keys)
        let name = values?.volumeName ?? url.lastPathComponent
        let format = values?.volumeLocalizedFormatDescription ?? L10n.get("folder")
        let writable = values?.volumeIsReadOnly != true && FileManager.default.isWritableFile(atPath: url.path)
        let access = writable ? L10n.get("volume_read_write") : L10n.get("volume_read_only")
        let status = String(format: L10n.get("volume_status"), name, format, access)
        if format.localizedCaseInsensitiveContains("ntfs") && !writable {
            return status + " — " + L10n.get("ntfs_read_only_status")
        }
        return status
    }

    @objc func copySelectionToClipboard() {
        placeSelectionOnClipboard(move: false)
    }

    @objc func cutSelectionToClipboard() {
        placeSelectionOnClipboard(move: true)
    }

    private func placeSelectionOnClipboard(move: Bool) {
        guard let pane = activePane else { return }
        let urls = pane.selectedEntries().filter { $0.isPhysical() }.map(\.url)
        guard !urls.isEmpty else {
            updateGlobalStatus(L10n.get("no_file_selected"))
            return
        }
        fileClipboard = FileClipboard(urls: urls, move: move)
        UIPasteboard.general.setObjects(urls.map { $0 as NSURL }, localOnly: false, expirationDate: nil)
        updateGlobalStatus(String(format: L10n.get(move ? "clipboard_cut" : "clipboard_copied"), urls.count))
    }

    @objc func pasteClipboard() {
        guard let pane = activePane, let target = pane.currentDirectory else { return }
        guard target.canWriteDirectory() else {
            updateGlobalStatus(L10n.get("target_not_writable"))
            return
        }
        let internalClipboard = fileClipboard
        let urls = internalClipboard?.urls ?? UIPasteboard.general.urls ?? []
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else {
            updateGlobalStatus(L10n.get("clipboard_empty"))
            return
        }
        executeClipboardPaste(urls: existing, move: internalClipboard?.move == true, targetPane: pane)
    }

    private func executeClipboardPaste(urls: [URL], move: Bool, targetPane: CommanderPane) {
        let targetURL = targetPane.currentDirectory.url
        showProgress(String(format: L10n.get(move ? "moving_items" : "copying_items"), urls.count), progress: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var moved: [(source: URL, destination: URL, replacedBackup: URL?)] = []
            var copied: [(source: URL, destination: URL, replacedBackup: URL?)] = []
            var failure: Error?

            for (index, source) in urls.enumerated() {
                let sourcePath = source.resolvingSymlinksInPath().path
                let targetPath = targetURL.resolvingSymlinksInPath().path
                var sourceIsDirectory: ObjCBool = false
                fm.fileExists(atPath: source.path, isDirectory: &sourceIsDirectory)
                if sourceIsDirectory.boolValue && (targetPath == sourcePath || targetPath.hasPrefix(sourcePath + "/")) {
                    failure = NSError(domain: "OpenCommander", code: 10, userInfo: [NSLocalizedDescriptionKey: String(format: L10n.get("cannot_copy_into_self"), source.lastPathComponent)])
                    break
                }
                let preferred = targetURL.appendingPathComponent(source.lastPathComponent)
                if preferred.standardizedFileURL == source.standardizedFileURL { continue }
                let destination = self.uniqueURL(in: targetURL, name: source.lastPathComponent)
                let accessed = source.startAccessingSecurityScopedResource()
                defer { if accessed { source.stopAccessingSecurityScopedResource() } }
                do {
                    if move {
                        try fm.moveItem(at: source, to: destination)
                        moved.append((source, destination, nil))
                    } else {
                        try fm.copyItem(at: source, to: destination)
                        copied.append((source, destination, nil))
                    }
                } catch {
                    failure = error
                    break
                }
                let progress = Int((Double(index + 1) / Double(max(1, urls.count))) * 100)
                DispatchQueue.main.async { self.updateProgress(progress: progress) }
            }

            DispatchQueue.main.async {
                if !moved.isEmpty { self.operationHistory.append(.move(files: moved)) }
                if !copied.isEmpty { self.operationHistory.append(.copy(files: copied)) }
                if move && failure == nil { self.fileClipboard = nil }
                self.refreshAllPanes(clearSelectionIn: [targetPane])
                if let failure {
                    self.finishProgress(String(format: L10n.get("error_prefix"), failure.localizedDescription))
                } else {
                    let count = move ? moved.count : copied.count
                    self.finishProgress(String(format: L10n.get(move ? "moved_items" : "copied_items"), count))
                }
            }
        }
    }

    @objc func selectAllInActivePane() {
        guard let pane = activePane else { return }
        pane.selectedKeys = Set(pane.visibleEntries.filter { !$0.isUpButton }.map { $0.key() })
        pane.updateSelectionStatus()
        pane.fileList.reloadData()
    }

    @objc func refreshActivePane() {
        guard let pane = activePane else { return }
        pane.reloadTreeKeepingExpansion()
        pane.refreshFiles()
        updateGlobalStatus(volumeStatus(for: pane.currentDirectory.url))
    }

    @objc func toggleHiddenFiles() {
        let visible = !UserDefaults.standard.bool(forKey: "show_hidden_files")
        UserDefaults.standard.set(visible, forKey: "show_hidden_files")
        leftPane.reloadTreeKeepingExpansion()
        rightPane.reloadTreeKeepingExpansion()
        leftPane.refreshFiles()
        rightPane.refreshFiles()
        updateGlobalStatus(L10n.get(visible ? "hidden_visible" : "hidden_hidden"))
    }

    @objc func openSelectedEntry() {
        guard let pane = activePane, let entry = pane.selectedEntries().first else {
            updateGlobalStatus(L10n.get("no_file_selected"))
            return
        }
        if entry.isDirectoryLike() {
            pane.openDirectory(entry)
        } else {
            openExternal(entry)
        }
    }

    @objc func previewSelectedEntry() {
        guard let entry = activePane?.selectedEntries().first else {
            updateGlobalStatus(L10n.get("no_file_selected"))
            return
        }
        if entry.isDirectoryLike() {
            showFileInfo()
        } else {
            openExternal(entry)
        }
    }

    @objc func duplicateSelection() {
        guard !operationInProgress, let pane = activePane else { return }
        let sources = pane.selectedEntries().filter { $0.isPhysical() }
        guard !sources.isEmpty else {
            updateGlobalStatus(L10n.get("no_file_selected"))
            return
        }
        guard pane.currentDirectory.canWriteDirectory() else {
            updateGlobalStatus(L10n.get("target_not_writable"))
            return
        }
        showProgress(String(format: L10n.get("duplicating_items"), sources.count), progress: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var copied: [(source: URL, destination: URL, replacedBackup: URL?)] = []
            var failure: Error?
            for (index, source) in sources.enumerated() {
                let destination = self.uniqueURL(in: pane.currentDirectory.url, name: source.name())
                do {
                    try fm.copyItem(at: source.url, to: destination)
                    copied.append((source.url, destination, nil))
                } catch {
                    failure = error
                    break
                }
                let progress = Int((Double(index + 1) / Double(sources.count)) * 100)
                DispatchQueue.main.async { self.updateProgress(progress: progress) }
            }
            DispatchQueue.main.async {
                if !copied.isEmpty { self.operationHistory.append(.copy(files: copied)) }
                self.refreshAllPanes(clearSelectionIn: [pane])
                if let failure {
                    self.finishProgress(String(format: L10n.get("error_prefix"), failure.localizedDescription))
                } else {
                    self.finishProgress(String(format: L10n.get("duplicated_items"), copied.count))
                }
            }
        }
    }

    @objc func showFileInfo() {
        guard let entry = activePane?.selectedEntries().first, entry.isPhysical() else {
            updateGlobalStatus(L10n.get("no_file_selected"))
            return
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: entry.url.path)
        let values = try? entry.url.resourceValues(forKeys: [.localizedTypeDescriptionKey])
        let kind = values?.localizedTypeDescription ?? (entry.isPhysicalDirectory() ? L10n.get("folder") : L10n.get("file"))
        let byteCount = (attributes?[.size] as? NSNumber)?.int64Value ?? entry.size()
        let byteFormatter = ByteCountFormatter()
        byteFormatter.countStyle = .file
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .medium
        let unknown = "—"
        let created = (attributes?[.creationDate] as? Date).map(dateFormatter.string) ?? unknown
        let modified = (attributes?[.modificationDate] as? Date).map(dateFormatter.string) ?? unknown
        let readable = FileManager.default.isReadableFile(atPath: entry.url.path)
        let writable = FileManager.default.isWritableFile(atPath: entry.url.path)
        let permissions = String(format: L10n.get("permissions_value"),
                                 L10n.get(readable ? "yes" : "no"),
                                 L10n.get(writable ? "yes" : "no"))
        let message = String(format: L10n.get("file_info_message"),
                             entry.name(), kind, entry.url.deletingLastPathComponent().path,
                             byteFormatter.string(fromByteCount: byteCount), created, modified, permissions)
        showScrollableDialog(title: L10n.get("file_info"), message: message)
    }

    @objc func moveSelectionToTrash() {
        let panes = selectedPanes()
        let sources = selectedEntriesFromPanes(panes)
        guard !sources.isEmpty else {
            updateGlobalStatus(L10n.get("no_file_selected"))
            return
        }
        guard sources.allSatisfy({ $0.isPhysical() }) else {
            updateGlobalStatus(L10n.get("zip_read_only"))
            return
        }
        executeDeleteOperation(panes: panes, sources: sources, toTrash: true)
    }

    @objc func showGoToFolderDialog() {
        let alert = UIAlertController(title: L10n.get("go_to_folder"), message: L10n.get("go_to_folder_prompt"), preferredStyle: .alert)
        alert.addTextField { field in
            field.text = self.activePane?.currentDirectory.url.path
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
        }
        alert.addAction(UIAlertAction(title: L10n.get("open"), style: .default) { [weak alert] _ in
            guard let value = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty,
                  let pane = self.activePane else { return }
            let expanded = (value as NSString).expandingTildeInPath
            self.openLocation(URL(fileURLWithPath: expanded, isDirectory: true), in: pane)
        })
        alert.addAction(UIAlertAction(title: L10n.get("cancel"), style: .cancel))
        present(alert, animated: true)
    }

    @objc func navigateBack() { activePane?.navigateBack() }
    @objc func navigateForward() { activePane?.navigateForward() }
    @objc func navigateUp() { activePane?.navigateUp() }

    @objc func openComputerRoot() { openSpecialLocation(URL(fileURLWithPath: "/", isDirectory: true)) }
    @objc func openHomeFolder() { openSpecialLocation(HostFileSystem.homeDirectory) }
    @objc func openDesktopFolder() { openSpecialLocation(HostFileSystem.desktopDirectory) }
    @objc func openDocumentsFolder() {
        openSpecialLocation(HostFileSystem.homeDirectory.appendingPathComponent("Documents", isDirectory: true))
    }
    @objc func openDownloadsFolder() { openSpecialLocation(HostFileSystem.downloadsDirectory) }

    private func openSpecialLocation(_ url: URL) {
        guard let pane = activePane else { return }
        openLocation(url, in: pane)
    }

    @objc func switchActivePane() {
        activePane = activePane === leftPane ? rightPane : leftPane
        if let pane = activePane {
            updateGlobalStatus(volumeStatus(for: pane.currentDirectory.url))
            pane.fileList?.becomeFirstResponder()
        }
    }

    @objc func clearSelection() {
        guard let pane = activePane else { return }
        pane.selectedKeys.removeAll()
        pane.updateSelectionStatus()
        pane.fileList?.reloadData()
    }

    @objc func createFolder() {
        guard let pane = activePane, pane.currentDirectory.canWriteDirectory() else {
            updateGlobalStatus(L10n.get("target_not_writable"))
            return
        }
        let alert = UIAlertController(title: L10n.get("new_folder"), message: nil, preferredStyle: .alert)
        alert.addTextField { $0.text = L10n.get("new_folder_name") }
        alert.addAction(UIAlertAction(title: L10n.get("new_folder"), style: .default) { [weak alert] _ in
            guard let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  self.isValidFileName(name) else { return }
            let url = self.uniqueURL(in: pane.currentDirectory.url, name: name)
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                pane.refreshFiles()
                self.updateGlobalStatus(String(format: L10n.get("folder_created"), url.lastPathComponent))
            } catch {
                self.updateGlobalStatus(String(format: L10n.get("cannot_create_folder"), error.localizedDescription))
            }
        })
        alert.addAction(UIAlertAction(title: L10n.get("cancel"), style: .cancel))
        present(alert, animated: true)
    }
}
