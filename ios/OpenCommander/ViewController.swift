import UIKit
import ZIPFoundation
import UniformTypeIdentifiers
import ImageIO
import QuickLook
import AVKit
import QuickLookThumbnailing
#if !targetEnvironment(macCatalyst)
import PhotosUI
import MediaPlayer
#endif


private final class ImageViewerViewController: UIViewController {
    private enum Media { case image(UIImage), playback(URL) }
    private let entries: [FileEntry]
    private var index: Int
    private var loadGeneration = 0
    private let imageView = UIImageView()
    private let titleLabel = UILabel()
    private let pageLabel = UILabel()
    private let errorLabel = UILabel()
    private let loadingIndicator = UIActivityIndicatorView(style: .large)
    private let retryButton = UIButton(type: .system)
    private var readCoordinator: NSFileCoordinator?
    private var vectorPreviewRequest: QLThumbnailGenerator.Request?
    private let playerController = AVPlayerViewController()
    private var playerStatus: NSKeyValueObservation?

    init(entries: [FileEntry], initialIndex: Int) {
        self.entries = entries
        self.index = initialIndex
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.accessibilityIdentifier = "ImageViewer"

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.isUserInteractionEnabled = true
        imageView.isAccessibilityElement = true
        imageView.accessibilityIdentifier = "ImageViewerImage"
        view.addSubview(imageView)

        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.textColor = .white
        errorLabel.font = .systemFont(ofSize: 16)
        errorLabel.textAlignment = .center
        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true
        errorLabel.accessibilityIdentifier = "ImageViewerError"
        view.addSubview(errorLabel)

        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.color = .white
        loadingIndicator.accessibilityLabel = L10n.get("image_loading")
        loadingIndicator.accessibilityIdentifier = "ImageViewerLoading"
        view.addSubview(loadingIndicator)
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.setTitle(L10n.get("directory_retry"), for: .normal)
        retryButton.accessibilityIdentifier = "ImageViewerRetry"
        retryButton.addTarget(self, action: #selector(retryImage), for: .touchUpInside)
        retryButton.isHidden = true
        view.addSubview(retryButton)

        let header = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)

        let closeButton = UIButton(type: .system)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setTitle("×", for: .normal)
        closeButton.setTitleColor(.white, for: .normal)
        closeButton.titleLabel?.font = .systemFont(ofSize: 32, weight: .light)
        closeButton.accessibilityIdentifier = "ImageViewerClose"
        closeButton.accessibilityLabel = L10n.get("cancel")
        closeButton.addTarget(self, action: #selector(closeViewer), for: .touchUpInside)
        header.contentView.addSubview(closeButton)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.accessibilityIdentifier = "ImageViewerTitle"
        header.contentView.addSubview(titleLabel)

        pageLabel.translatesAutoresizingMaskIntoConstraints = false
        pageLabel.textColor = .white
        pageLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        pageLabel.textAlignment = .center
        pageLabel.accessibilityIdentifier = "ImageViewerPage"
        header.contentView.addSubview(pageLabel)

        let navigation = UIStackView()
        navigation.axis = .horizontal
        navigation.translatesAutoresizingMaskIntoConstraints = false
        for (symbol, action, identifier) in [("chevron.left", #selector(previousMedia), "MediaPrevious"),
                                             ("chevron.right", #selector(nextMedia), "MediaNext")] {
            let button = UIButton(type: .system)
            button.setImage(UIImage(systemName: symbol), for: .normal)
            button.tintColor = .white
            button.accessibilityIdentifier = identifier
            button.accessibilityLabel = L10n.get(identifier == "MediaPrevious" ? "back" : "forward")
            button.addTarget(self, action: action, for: .touchUpInside)
            button.widthAnchor.constraint(equalToConstant: 44).isActive = true
            navigation.addArrangedSubview(button)
        }
        header.contentView.addSubview(navigation)
        NSLayoutConstraint.activate([
            navigation.trailingAnchor.constraint(equalTo: pageLabel.leadingAnchor, constant: -8),
            navigation.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            navigation.heightAnchor.constraint(equalToConstant: 44),
            navigation.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8)])
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 56),

            closeButton.leadingAnchor.constraint(equalTo: header.contentView.leadingAnchor, constant: 4),
            closeButton.bottomAnchor.constraint(equalTo: header.contentView.bottomAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 56),
            closeButton.heightAnchor.constraint(equalToConstant: 56),

            titleLabel.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 4),
            titleLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            pageLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            pageLabel.trailingAnchor.constraint(equalTo: header.contentView.trailingAnchor, constant: -12),
            pageLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            pageLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 54),

            imageView.topAnchor.constraint(equalTo: header.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            imageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            errorLabel.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
            errorLabel.leadingAnchor.constraint(greaterThanOrEqualTo: imageView.leadingAnchor, constant: 24),
            errorLabel.trailingAnchor.constraint(lessThanOrEqualTo: imageView.trailingAnchor, constant: -24),
            loadingIndicator.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: imageView.centerYAnchor, constant: -60),
            retryButton.topAnchor.constraint(equalTo: errorLabel.bottomAnchor, constant: 16),
            retryButton.centerXAnchor.constraint(equalTo: imageView.centerXAnchor)
        ])
        addChild(playerController)
        playerController.view.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(playerController.view, aboveSubview: imageView)
        NSLayoutConstraint.activate([
            playerController.view.topAnchor.constraint(equalTo: imageView.topAnchor),
            playerController.view.bottomAnchor.constraint(equalTo: imageView.bottomAnchor),
            playerController.view.leadingAnchor.constraint(equalTo: imageView.leadingAnchor),
            playerController.view.trailingAnchor.constraint(equalTo: imageView.trailingAnchor)])
        playerController.didMove(toParent: self)
        playerController.view.isHidden = true
        view.bringSubviewToFront(errorLabel)
        view.bringSubviewToFront(loadingIndicator)
        view.bringSubviewToFront(retryButton)

        let swipeLeft = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
        swipeLeft.direction = .left
        imageView.addGestureRecognizer(swipeLeft)
        let swipeRight = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
        swipeRight.direction = .right
        imageView.addGestureRecognizer(swipeRight)

        showCurrentImage()
    }

    @objc private func closeViewer() {
        stopPlayback()
        if let vectorPreviewRequest { QLThumbnailGenerator.shared.cancel(vectorPreviewRequest) }
        vectorPreviewRequest = nil
        loadGeneration += 1
        readCoordinator?.cancel()
        dismiss(animated: true)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopPlayback()
        if let vectorPreviewRequest { QLThumbnailGenerator.shared.cancel(vectorPreviewRequest) }
        vectorPreviewRequest = nil
        loadGeneration += 1
        readCoordinator?.cancel()
    }

    @objc private func retryImage() { showCurrentImage() }
    private func stopPlayback() {
        playerController.player?.pause()
        playerController.player = nil
        playerStatus = nil
    }
    override var canBecomeFirstResponder: Bool { true }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }
    override var keyCommands: [UIKeyCommand]? {
        let commands = [UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(previousMedia)),
         UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(nextMedia)),
         UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(closeViewer)),
         UIKeyCommand(input: " ", modifierFlags: [], action: #selector(togglePlayback))]
        commands.forEach { $0.wantsPriorityOverSystemBehavior = true }
        return commands
    }
    @objc private func previousMedia() { advanceMedia(-1) }
    @objc private func nextMedia() { advanceMedia(1) }
    @objc private func togglePlayback() {
        guard let player = playerController.player else { return }
        if player.timeControlStatus == .playing { player.pause() } else { player.play() }
    }
    private func advanceMedia(_ amount: Int) {
        guard entries.indices.contains(index + amount) else { return }
        index += amount
        showCurrentImage()
    }

    @objc private func handleSwipe(_ recognizer: UISwipeGestureRecognizer) {
        let requested = index + (recognizer.direction == .left ? 1 : -1)
        guard entries.indices.contains(requested) else { return }
        index = requested
        showCurrentImage()
    }

    private func showCurrentImage() {
        if let vectorPreviewRequest { QLThumbnailGenerator.shared.cancel(vectorPreviewRequest) }
        vectorPreviewRequest = nil
        stopPlayback()
        playerController.view.isHidden = true
        let entry = entries[index]
        titleLabel.text = entry.name()
        pageLabel.text = "\(index + 1) / \(entries.count)"
        imageView.accessibilityLabel = entry.name()
        imageView.image = nil
        errorLabel.isHidden = true
        retryButton.isHidden = true
        loadingIndicator.startAnimating()
        readCoordinator?.cancel()
        let coordinator = NSFileCoordinator()
        readCoordinator = coordinator
        loadGeneration += 1
        let generation = loadGeneration
        let scale = UIScreen.main.scale
        let maximumPixelSize = max(UIScreen.main.bounds.width, UIScreen.main.bounds.height) * scale * 2

        if entry.mimeType() == "image/svg+xml", entry.isPhysical() {
            let request = QLThumbnailGenerator.Request(fileAt: entry.url,
                size: CGSize(width: min(2048, maximumPixelSize), height: min(2048, maximumPixelSize)), scale: 1, representationTypes: .thumbnail)
            vectorPreviewRequest = request
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, error in
                DispatchQueue.main.async {
                    guard let self, self.loadGeneration == generation else { return }
                    self.vectorPreviewRequest = nil; self.readCoordinator = nil
                    self.loadingIndicator.stopAnimating()
                    if let representation { self.imageView.image = representation.uiImage }
                    else {
                        self.errorLabel.text = error?.localizedDescription ?? L10n.get("preview_unavailable")
                        self.errorLabel.isHidden = false; self.retryButton.isHidden = false
                    }
                }
            }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<Media, Error> = autoreleasepool {
                Result {
                    if !entry.mimeType().hasPrefix("image/") {
                        var error: NSError?
                        var prepared: Result<URL, Error>?
                        coordinator.coordinate(readingItemAt: entry.url, options: .withoutChanges, error: &error) { url in
                            prepared = Result { try entry.materializedURLForOpening(sourceURL: url) }
                        }
                        if let error { throw error }
                        guard let prepared else { throw CocoaError(.fileReadUnknown) }
                        return .playback(try prepared.get())
                    }
                    let image = try ImagePreviewLoader.load(at: entry.url,
                        maximumPixelSize: Int(maximumPixelSize), coordinator: coordinator) {
                        try entry.materializedURLForOpening(sourceURL: $0)
                    }
                    return .image(UIImage(cgImage: image))
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.loadGeneration == generation else { return }
                self.loadingIndicator.stopAnimating()
                self.readCoordinator = nil
                self.errorLabel.isHidden = true
                switch result {
                case .success(.image(let image)): self.imageView.image = image
                case .success(.playback(let url)):
                    let item = AVPlayerItem(url: url)
                    let player = AVPlayer(playerItem: item)
                    self.playerController.player = player
                    self.playerController.showsPlaybackControls = entry.mimeType().hasPrefix("video/")
                    self.playerController.view.isHidden = false
                    self.playerStatus = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                        DispatchQueue.main.async {
                            guard let self, self.loadGeneration == generation else { return }
                            if item.status == .failed {
                                self.errorLabel.text = item.error?.localizedDescription ?? L10n.get("preview_unavailable")
                                self.errorLabel.isHidden = false
                                self.retryButton.isHidden = false
                            }
                        }
                    }
                    player.play()
                case .failure(let error):
                    if error is ImagePreviewLoader.PreviewError {
                        self.errorLabel.text = L10n.get("image_invalid")
                    } else if (error as NSError).domain == "NSFileProviderErrorDomain" {
                        self.errorLabel.text = String(format: L10n.get("image_provider_error"), (error as NSError).code)
                    } else {
                        self.errorLabel.text = String(format: L10n.get("image_read_error"), error.localizedDescription)
                    }
                    self.errorLabel.isHidden = false
                    self.retryButton.isHidden = false
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.loadGeneration == generation, self.readCoordinator != nil else { return }
            self.errorLabel.text = L10n.get("image_waiting")
            self.errorLabel.isHidden = false
        }
    }
}


#if targetEnvironment(macCatalyst)
private final class DesktopLocationSettingsViewController: UITableViewController {
    var entries: [DesktopLocationPreference]
    var changed: ([DesktopLocationPreference]) -> Void
    var chooseFolder: (@escaping (URL?) -> Void) -> Void
    var languageChanged: ((String) -> Void)?
    var darkMode = false
    var themeChanged: (() -> Void)?
    var defaultAppRequested: (() -> Void)?
    var legalRequested: (() -> Void)?
    var oneDriveRequested: (() -> Void)?
    var locationDetails: [String: String] = [:]

    init(entries: [DesktopLocationPreference], changed: @escaping ([DesktopLocationPreference]) -> Void,
         chooseFolder: @escaping (@escaping (URL?) -> Void) -> Void) {
        self.entries = entries; self.changed = changed; self.chooseFolder = chooseFolder
        super.init(style: .insetGrouped)
        title = L10n.get("location_settings")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: L10n.get("settings_done"), style: .done,
            target: self, action: #selector(close))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: L10n.get("location_add"), style: .plain,
            target: self, action: #selector(addLocation))
        tableView.accessibilityIdentifier = "LocationSettingsList"
    }
    @objc private func close() { dismiss(animated: true) }
    private func save() { changed(entries); tableView.reloadData() }
    override func numberOfSections(in tableView: UITableView) -> Int { 2 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 5 : entries.count
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 1 ? L10n.get("location_settings_help") : nil
    }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 1 ? L10n.get("location_settings") : nil
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 {
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            if indexPath.row == 1 {
                cell.textLabel?.text = L10n.get("dark")
                let toggle = UISwitch()
                toggle.isOn = darkMode
                toggle.accessibilityIdentifier = "SettingsThemeSwitch"
                toggle.addAction(UIAction { [weak self] _ in
                    guard let self else { return }
                    self.darkMode.toggle()
                    self.themeChanged?()
                    self.overrideUserInterfaceStyle = self.darkMode ? .dark : .light
                }, for: .valueChanged)
                cell.accessoryView = toggle
                cell.selectionStyle = .none
                return cell
            }
            if indexPath.row > 1 {
                cell.textLabel?.text = indexPath.row == 4 ? "OneDrive online" : L10n.get(indexPath.row == 2 ? "folder_default_title" : "legal_short")
                cell.accessoryType = .disclosureIndicator
                return cell
            }
            cell.textLabel?.text = L10n.get("language")
            cell.selectionStyle = .none
            let dropdown = UIButton(type: .system)
            let selected = UserDefaults.standard.string(forKey: "language") ?? ""
            let choices = ViewController.languageChoices
            dropdown.setTitle((choices.first { $0.1 == selected }?.0 ?? L10n.get("language_system")) + " ▾", for: .normal)
            dropdown.accessibilityIdentifier = "SettingsLanguageDropdown"
            dropdown.accessibilityLabel = L10n.get("language")
            dropdown.showsMenuAsPrimaryAction = true
            dropdown.menu = UIMenu(children: choices.map { name, code in
                UIAction(title: name, state: code == selected ? .on : .off) { [weak self] _ in
                    guard let self else { return }
                    self.languageChanged?(code)
                    self.title = L10n.get("location_settings")
                    self.navigationItem.leftBarButtonItem?.title = L10n.get("settings_done")
                    self.navigationItem.rightBarButtonItem?.title = L10n.get("location_add")
                    self.tableView.reloadData()
                }
            })
            dropdown.sizeToFit()
            cell.accessoryView = dropdown
            return cell
        }
        let entry = entries[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = entry.name
        cell.detailTextLabel?.text = locationDetails[entry.path] ?? entry.path
        cell.detailTextLabel?.numberOfLines = 2
        cell.accessibilityIdentifier = "LocationSetting-\(entry.path)"
        let toggle = UISwitch()
        toggle.isOn = entry.enabled
        toggle.accessibilityLabel = entry.name
        toggle.accessibilityIdentifier = "LocationVisible-\(entry.path)"
        toggle.addAction(UIAction { [weak self, weak toggle] _ in
            guard let self, let index = self.entries.firstIndex(where: { $0.path == entry.path }) else { return }
            self.entries[index].enabled = toggle?.isOn == true
            self.entries[index].visibilityConfigured = true
            self.save()
        }, for: .valueChanged)
        cell.accessoryView = toggle
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if indexPath.section == 0 {
            let action = indexPath.row == 2 ? defaultAppRequested : indexPath.row == 3 ? legalRequested : indexPath.row == 4 ? oneDriveRequested : nil
            if let action { dismiss(animated: true, completion: action) }
            return
        }
        let entry = entries[indexPath.row]
        let alert = UIAlertController(title: L10n.get("location_rename"), message: entry.path, preferredStyle: .alert)
        alert.addTextField { $0.text = entry.name }
        alert.addAction(UIAlertAction(title: L10n.get("settings_save"), style: .default) { [weak self] _ in
            guard let self, let name = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty, let index = self.entries.firstIndex(where: { $0.path == entry.path }) else { return }
            self.entries[index].name = name; self.save()
        })
        if entry.custom {
            alert.addAction(UIAlertAction(title: L10n.get("location_remove"), style: .destructive) { [weak self] _ in
                self?.entries.removeAll { $0.path == entry.path }; self?.save()
            })
        }
        alert.addAction(UIAlertAction(title: L10n.get("cancel"), style: .cancel))
        present(alert, animated: true)
    }
    @objc private func addLocation() {
        chooseFolder { [weak self] url in
            guard let self, let url else { return }
            let scope = url.startAccessingSecurityScopedResource()
            defer { if scope { url.stopAccessingSecurityScopedResource() } }
            let canonical = url.resolvingSymlinksInPath().standardizedFileURL
            if !self.entries.contains(where: { $0.path == canonical.path }) {
                self.entries.append(DesktopLocationPreference(path: canonical.path, name: canonical.lastPathComponent,
                    enabled: true, custom: true,
                    bookmark: try? url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)))
                self.save()
            }
        }
    }
}
#endif

private final class CompactActionToolbar: UIView {
    private let buttons: [UIButton]
#if targetEnvironment(macCatalyst)
    private let gap: CGFloat = 6
#else
    private let gap: CGFloat = 2
#endif
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
#if targetEnvironment(macCatalyst)
        CGSize(width: UIView.noIntrinsicMetric, height: 36)
#else
        CGSize(width: UIView.noIntrinsicMetric, height: 28)
#endif
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0 else { return }
        let buttons = self.buttons.filter { !$0.isHidden }
        guard !buttons.isEmpty else { return }
        func widths(fontSize: CGFloat) -> [CGFloat] {
            let font = UIFont.systemFont(ofSize: fontSize)
            return buttons.map {
                max(24, ceil((($0.currentTitle ?? "") as NSString).size(withAttributes: [.font: font]).width)
                    + horizontalPadding + ($0.currentImage == nil ? 0 : 20))
            }
        }
        let spacing = CGFloat(max(0, buttons.count - 1)) * gap
        // Keep every complete localized label in one row, including Move.
        // Use one shared font size so longer translations remain consistent.
#if targetEnvironment(macCatalyst)
        var fontSize: CGFloat = 13
#else
        var fontSize: CGFloat = 10
#endif
        var sizes = widths(fontSize: fontSize)
        while sizes.reduce(0, +) + spacing > bounds.width && fontSize > 1 {
            fontSize -= 0.1
            sizes = widths(fontSize: fontSize)
        }
        var extra = max(0, bounds.width - sizes.reduce(0, +) - spacing) / CGFloat(buttons.count)
#if targetEnvironment(macCatalyst)
        extra = min(extra, 24)
#endif
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
            if let data = try? JSONEncoder().encode(operationHistory) {
                UserDefaults.standard.set(data, forKey: "operation_history_v1")
            }
            DispatchQueue.main.async {
                if self.isViewLoaded, self.historyPanel != nil { self.rebuildHistoryPanel() }
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
            // Shared Linux desktop palette, rendered with native UIKit controls.
            let bg = UIColor(hex: darkMode ? "#171e2d" : "#eaf0fa")
            let panel = UIColor(hex: darkMode ? "#242e40" : "#ffffff")
            let inset = UIColor(hex: darkMode ? "#1c2638" : "#f0f4fc")
            let foreground = UIColor(hex: darkMode ? "#e8eef9" : "#202c43")
            let border = UIColor(hex: darkMode ? "#40516b" : "#c9d6e8")
            appBackground = bg; headerBackground = panel; panelBackground = panel
            columnBackground = panel; fileBackground = panel; treeBackground = inset
            columnHeaderBackground = inset; pathBackground = inset; buttonBackground = panel
            panelBorder = border; columnBorder = border; pathBorder = border; buttonBorder = border
            primaryText = foreground; headerText = foreground; buttonText = foreground
            secondaryText = UIColor(hex: darkMode ? "#afbed3" : "#53647c")
            selectionBackground = UIColor(hex: darkMode ? "#334f76" : "#dceaff")
        }
    }

    var darkMode = false
    var theme: ThemeColors!

    var leftPane: CommanderPane!
    var rightPane: CommanderPane!
    weak var activePane: CommanderPane?
    private weak var extractActionButton: UIButton?
    private weak var desktopActionToolbar: CompactActionToolbar?
    private weak var hiddenActionButton: UIButton?
    weak var activeDragPane: CommanderPane?
    var externalDropInProgress = false
    private(set) var fileOperationInProgress = false
    var historyExpanded = false
    var moveMode = false
    private(set) var operationInProgress = false
    private let operationCancellation = FileOperationCancellation()
    private var cancelOperationButton: UIButton?
    private var fileClipboard: FileClipboard?
    private weak var folderPickerPane: CommanderPane?
    private var folderPickerAppliesToBothPanes = false
    private weak var storageLocationsStack: UIStackView?
    private var storageLocationsRefreshGeneration = 0
    private var storageLocationsRefreshPending = false
    private var securityScopedURLs: [URL] = []
    private var failedRestoredPaneTitles = Set<String>()
#if !targetEnvironment(macCatalyst)
    private weak var mediaImportPane: CommanderPane?
    private var mediaImportInProgress = false
#endif
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
    private var documentPreviewURLs: [URL] = []
    private var documentPreparationPending = false
    private var documentPreparationGeneration = 0
    private var fileInfoRequest: UUID?
    private var storageRefreshTimer: Timer?
    private var operationReadCoordinator: NSFileCoordinator?

    var historyPanel: UIView!
    var progressText: UILabel!
    var progressBar: UIProgressView!
    private let progressActivity = UIActivityIndicatorView(style: .medium)
    var globalStatus: UILabel!

    func dp(_ value: CGFloat) -> CGFloat {
        return value
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        darkMode = UserDefaults.standard.bool(forKey: "dark_mode")
        if let data = UserDefaults.standard.data(forKey: "operation_history_v1"),
           let history = try? JSONDecoder().decode([OperationType].self, from: data) {
            operationHistory = history
        }
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
        rightPane = CommanderPane(title: "2", root: FileEntry(url: rightURL, parent: nil), accent: "#147454", viewController: self)
        activePane = leftPane
        
        buildLayout()
#if targetEnvironment(macCatalyst)
        storageRefreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, !self.operationInProgress, UIApplication.shared.applicationState == .active else { return }
            self.reloadStorageLocationsBar()
        }
#endif
        if failedRestoredPaneTitles.isEmpty {
            maybeShowFirstRunHelp()
        } else {
            showRestoredFolderAccessRecovery()
        }
    }

    deinit {
        storageRefreshTimer?.invalidate()
        securityScopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
    }

    @objc private func applicationDidBecomeActiveForAccessCheck() {
#if targetEnvironment(macCatalyst)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            self.refreshFullDiskAccessStatus(showFeedback: false)
            self.reloadStorageLocationsBar()
            if !self.operationInProgress {
                for pane in [self.leftPane, self.rightPane].compactMap({ $0 }) where
                    HostFileSystem.isCloudStorage(pane.currentDirectory.url) {
                    pane.reloadTreeKeepingExpansion()
                    pane.refreshFiles()
                }
            }
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
        view.overrideUserInterfaceStyle = darkMode ? .dark : .light
        view.tintColor = .systemBlue
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
        progressActivity.removeFromSuperview()
        progressActivity.translatesAutoresizingMaskIntoConstraints = false
        progressActivity.accessibilityIdentifier = "CloudTransferProgress"
        progressContainer.addSubview(progressActivity)
        progressContainer.addSubview(progressText)
        progressText.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            progressText.topAnchor.constraint(equalTo: progressContainer.topAnchor, constant: dp(8)),
            progressText.bottomAnchor.constraint(equalTo: progressContainer.bottomAnchor, constant: -dp(3)),
            progressActivity.leadingAnchor.constraint(equalTo: progressContainer.leadingAnchor, constant: dp(4)),
            progressActivity.centerYAnchor.constraint(equalTo: progressText.centerYAnchor),
            progressText.leadingAnchor.constraint(equalTo: progressContainer.leadingAnchor, constant: dp(30)),
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
#if targetEnvironment(macCatalyst)
        title.font = .systemFont(ofSize: 17, weight: .semibold)
#endif
        title.adjustsFontSizeToFitWidth = true
        title.minimumScaleFactor = 0.7
        let titleRow = UIStackView(arrangedSubviews: [title])
        titleRow.axis = .horizontal
        titleRow.alignment = .center
        titleRow.spacing = 4
#if targetEnvironment(macCatalyst)
        titleRow.spacing = 12
        topBar.layoutMargins = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        topBar.spacing = 8
#endif
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

#if targetEnvironment(macCatalyst)
        let modeRow = UIStackView()
        modeRow.axis = .horizontal
        modeRow.alignment = .center
        modeRow.spacing = 6
        for text in [L10n.get("copy"), L10n.get("move")] {
            let label = UILabel()
            label.text = text
            label.font = .systemFont(ofSize: 13)
            label.textColor = theme.primaryText
            modeRow.addArrangedSubview(label)
        }
        let modeSwitch = UISwitch()
        modeSwitch.isOn = moveMode
        modeSwitch.onTintColor = UIColor(hex: "#238465")
        modeSwitch.accessibilityIdentifier = "OperationModeSwitch"
        modeSwitch.accessibilityLabel = "\(L10n.get("copy")) / \(L10n.get("move"))"
        modeSwitch.addAction(UIAction { [weak self, weak modeSwitch] _ in
            guard let self, let modeSwitch else { return }
            self.moveMode = modeSwitch.isOn
            self.updateGlobalStatus(L10n.get(self.moveMode ? "operation_mode_move_active" : "operation_mode_copy_active"))
        }, for: .valueChanged)
        modeRow.insertArrangedSubview(modeSwitch, at: 1)
        titleRow.addArrangedSubview(modeRow)
        let headerButtons = [helpButton]
#else
        let headerButtons = [helpButton, legalButton, languageButton!]
#endif
        for button in headerButtons {
            button.constraints.filter { $0.firstAttribute == .height }.forEach { $0.isActive = false }
            button.titleLabel?.font = .systemFont(ofSize: 10)
#if targetEnvironment(macCatalyst)
            button.titleLabel?.font = .systemFont(ofSize: 12)
#endif
            button.titleLabel?.numberOfLines = 1
            button.contentEdgeInsets = UIEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
            button.setContentHuggingPriority(.required, for: .horizontal)
            titleRow.addArrangedSubview(button)
        }
#if targetEnvironment(macCatalyst)
        openFolderButton = miniButton(label: L10n.get("drives"))
        let settingsButton = miniButton(label: L10n.get("location_settings"))
        settingsButton.accessibilityIdentifier = "LocationSettingsButton"
        settingsButton.addTarget(self, action: #selector(showLocationSettings), for: .touchUpInside)
        titleRow.addArrangedSubview(settingsButton)
#else
        openFolderButton = miniButton(label: L10n.get("choose_folder"))
#endif
        openFolderButton.accessibilityIdentifier = "OpenFolderButton"
        tintButton(button: openFolderButton, lightFill: "#EAF7FF", lightStroke: "#70AFD1", lightText: "#164B68", darkFill: "#153747", darkStroke: "#4388A8", darkText: "#E3F6FF")
        openFolderButton.addTarget(self, action: #selector(showComputerLocations), for: .touchUpInside)

#if !targetEnvironment(macCatalyst)
        let toolbar = CompactActionToolbar(buttons: [openFolderButton, undoButton, deleteButton, renameButton,
            operationButton, historyButton, zipButton, themeButton])
        toolbar.accessibilityIdentifier = "ActionToolbar"
        topBar.addArrangedSubview(toolbar)
#endif
#if targetEnvironment(macCatalyst)
        let moreActions: [(String, Selector)] = [
            ("new_folder", #selector(createFolder)), ("extract_archive", #selector(extractSelection)),
            ("preview", #selector(previewSelectedEntry)), ("toggle_hidden", #selector(toggleHiddenFiles)),
            ("commander_tools", #selector(showCommanderToolsMenu)),
            ("commander_search_button", #selector(showCommanderSearch))]
        let extraButtons = moreActions.map { key, action -> UIButton in
            let button = miniButton(label: L10n.get(key))
            button.accessibilityIdentifier = "DesktopAction-\(key)"
            if key == "commander_search_button" { button.accessibilityIdentifier = "CommanderSearchButton" }
            button.addTarget(self, action: action, for: .touchUpInside)
            if key == "extract_archive" { extractActionButton = button }
            if key == "toggle_hidden" { hiddenActionButton = button }
            return button
        }
        let toolbar = CompactActionToolbar(buttons: [renameButton, extraButtons[0], deleteButton, zipButton,
            extraButtons[1], extraButtons[2], undoButton, historyButton, extraButtons[5], extraButtons[4], extraButtons[3]])
        tintButton(button: extraButtons[4], lightFill: "#e9f8ef", lightStroke: "#147454", lightText: "#147454",
            darkFill: "#173f2a", darkStroke: "#79dcb9", darkText: "#79dcb9")
        for button in [renameButton, extraButtons[2], extraButtons[5]].compactMap({ $0 }) {
            tintButton(button: button, lightFill: "#e8f1ff", lightStroke: "#185bb5", lightText: "#185bb5",
                darkFill: "#1f344d", darkStroke: "#88baff", darkText: "#88baff")
        }
        tintButton(button: extraButtons[0], lightFill: "#e9f8ef", lightStroke: "#147454", lightText: "#147454",
            darkFill: "#173f2a", darkStroke: "#79dcb9", darkText: "#79dcb9")
        for button in [zipButton, extraButtons[1], undoButton].compactMap({ $0 }) {
            tintButton(button: button, lightFill: "#fff4d8", lightStroke: "#946400", lightText: "#946400",
                darkFill: "#4b3514", darkStroke: "#e3b65d", darkText: "#e3b65d")
        }
        toolbar.accessibilityIdentifier = "ActionToolbar"
        desktopActionToolbar = toolbar
        topBar.addArrangedSubview(toolbar)
        updateDesktopActions()
#endif
        return topBar
    }

    func updateDesktopActions() {
#if targetEnvironment(macCatalyst)
        let local = activePane?.onlineNavigation == nil
        for button in [renameButton, deleteButton] { button?.isEnabled = (local || activePane?.onlineBrowser?.hasSelection == true) && !operationInProgress }
        zipButton?.isEnabled = (local || activePane?.onlineBrowser?.hasSelection == true) && !operationInProgress
#endif
        let selected = activePane?.selectedEntries() ?? []
        let archiveContext = activePane?.currentDirectory.isZipEntry() == true || activePane?.currentDirectory.isZipArchive() == true
        var showsExtraction = DesktopInteractionPolicy.showsExtraction(archiveContext: archiveContext,
            selectedArchives: selected.map { $0.isZipArchive() || $0.isZipEntry() })
#if targetEnvironment(macCatalyst)
        if let browser = activePane?.onlineBrowser { showsExtraction = browser.hasSelectedArchives }
#endif
        extractActionButton?.isHidden = !showsExtraction
        extractActionButton?.isEnabled = !operationInProgress && showsExtraction
        desktopActionToolbar?.setNeedsLayout()
        let hidden = UserDefaults.standard.bool(forKey: "show_hidden_files")
        hiddenActionButton?.setImage(UIImage(systemName: hidden ? "checkmark.square.fill" : "square"), for: .normal)
        hiddenActionButton?.isSelected = hidden
        hiddenActionButton?.accessibilityValue = L10n.get(hidden ? "hidden_visible" : "hidden_hidden")
    }

    override var keyCommands: [UIKeyCommand]? {
        if operationInProgress || presentedViewController != nil { return [] }
        // Do not intercept Return, Delete, Cmd-C/V or Space while the user
        // edits a destination path (or a text field in a presented dialog).
        func editingText(in view: UIView) -> Bool {
            if let field = view as? UITextField, field.isEditing { return true }
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
            key(L10n.get("commander_search"), "f", command, #selector(showCommanderSearch)),
            key(L10n.get("commander_compare"), "c", [command, .alternate], #selector(showCommanderCompare)),
            key(L10n.get("commander_rename"), "m", [command, .shift], #selector(showCommanderRename)),
            key(L10n.get("undo"), "z", command, #selector(undoLastOperation)),
            key(L10n.get("refresh"), "r", command, #selector(refreshActivePane)),
            key(L10n.get("new_folder"), "n", [command, .shift], #selector(createFolder)),
            key(L10n.get("toggle_hidden"), ".", [command, .shift], #selector(toggleHiddenFiles)),
            key(L10n.get("delete_button"), UIKeyCommand.inputDelete, [], #selector(confirmDeleteSelection))
        ]
#if targetEnvironment(macCatalyst)
        commands.append(contentsOf: [
            key(L10n.get("rename_button"), UIKeyCommand.f2, [], #selector(showRenameDialog)),
            key(L10n.get("copy"), UIKeyCommand.f5, [], #selector(copyToOtherPane)),
            key(L10n.get("move"), UIKeyCommand.f6, [], #selector(moveToOtherPane)),
            key(L10n.get("open"), "o", command, #selector(openSelectedEntry)),
            key(L10n.get("open"), UIKeyCommand.inputDownArrow, command, #selector(openSelectedEntry)),
            key(L10n.get("preview"), " ", [], #selector(previewSelectedEntry)),
            key(L10n.get("preview"), "y", command, #selector(previewSelectedEntry)),
            key(L10n.get("open"), "\r", [], #selector(openSelectedEntry)),
            key(L10n.get("help"), UIKeyCommand.f1, [], #selector(showHelpDialog)),
            key(L10n.get("location_settings"), ",", command, #selector(showLocationSettings)),
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
#if targetEnvironment(macCatalyst)
        let button = UIButton(type: .custom)
#else
        let button = UIButton(type: .system)
#endif
        button.setTitle(label, for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 14)
        button.titleLabel?.numberOfLines = 0
        button.titleLabel?.textAlignment = .center
        button.layer.cornerRadius = 8
        button.layer.borderWidth = 1
        button.backgroundColor = theme.buttonBackground
        button.layer.borderColor = theme.buttonBorder.cgColor
        button.setTitleColor(theme.buttonText, for: .normal)
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
        guard storageLocationsStack != nil, !storageLocationsRefreshPending else { return }
        storageLocationsRefreshPending = true
        storageLocationsRefreshGeneration += 1
        let generation = storageLocationsRefreshGeneration

        DispatchQueue.global(qos: .utility).async {
            let discoveredLocations = HostFileSystem.availableStorageLocations()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.storageLocationsRefreshGeneration == generation else { return }
                self.storageLocationsRefreshPending = false
                self.renderStorageLocationsBar(discoveredLocations: discoveredLocations)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.storageLocationsRefreshGeneration == generation, self.storageLocationsRefreshPending else { return }
            self.storageLocationsRefreshPending = false
            self.storageLocationsRefreshGeneration += 1
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
            (L10n.get("downloads_folder"), HostFileSystem.downloadsDirectory, L10n.get("downloads_folder")),
            (L10n.get("location_desktop"), HostFileSystem.desktopDirectory, L10n.get("home_folder")),
            (L10n.get("location_documents"), HostFileSystem.homeDirectory.appendingPathComponent("Documents"), L10n.get("home_folder"))
        ]
        for location in discoveredLocations {
            let category: String
            switch location.kind {
            case .externalDrive: category = L10n.get("external_drive")
            case .networkShare: category = L10n.get("network_share")
            case .cloudStorage: category = L10n.get("cloud_storage")
            }
            let path = location.url.resolvingSymlinksInPath().standardizedFileURL.path
            let preference = DesktopLocationPreferences.load().first { $0.path == path }
            if !location.visibleByDefault && preference?.visibilityConfigured != true && preference?.custom != true { continue }
            let name = location.displayName
            locations.append((name, location.url, category))
        }

        var addedPaths = Set<String>()
        let preferences = DesktopLocationPreferences.load()
        for entry in preferences where entry.custom && entry.enabled {
            var url = URL(fileURLWithPath: entry.path, isDirectory: true)
            if let bookmark = entry.bookmark {
                var stale = false
                if let restored = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil,
                    bookmarkDataIsStale: &stale) {
                    url = restored
                    if !securityScopedURLs.contains(url), url.startAccessingSecurityScopedResource() { securityScopedURLs.append(url) }
                }
            }
            locations.append((entry.name, url, L10n.get("choose_folder")))
        }
        let connections = miniButton(label: L10n.get("connections"))
        connections.accessibilityIdentifier = "DesktopAction-connections"
        connections.addTarget(self, action: #selector(showConnections), for: .touchUpInside)
        stack.addArrangedSubview(connections)
        let onlinePreference = preferences.first { $0.path == DesktopLocationPreferences.oneDriveOnlinePath }
        if onlinePreference?.enabled != false {
            let online = miniButton(label: onlinePreference?.name ?? "OneDrive online")
            online.accessibilityIdentifier = "Location-OneDriveOnline"
            online.addAction(UIAction { [weak self] _ in self?.openOneDriveOnline() }, for: .touchUpInside)
            stack.addArrangedSubview(online)
        }
        for location in locations where addedPaths.insert(location.url.resolvingSymlinksInPath().standardizedFileURL.path).inserted {
            let preference = preferences.first { $0.path == location.url.resolvingSymlinksInPath().standardizedFileURL.path }
            if preference?.enabled == false { continue }
            let button = UIButton(type: .system)
            let stockHomeNames = ["Home Folder", "Benutzerordner"]
            let discovered = discoveredLocations.first { $0.url == location.url }
            let legacyName = discovered?.previousDefaultNames.contains(preference?.name ?? "") == true
            let title = legacyName ? location.name : location.url == HostFileSystem.homeDirectory && stockHomeNames.contains(preference?.name ?? "")
                ? L10n.get("home_folder") : preference?.name ?? location.name
            button.setTitle(title, for: .normal)
            button.setTitleColor(theme.primaryText, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 11, weight: .medium)
            button.titleLabel?.lineBreakMode = .byTruncatingMiddle
            button.widthAnchor.constraint(lessThanOrEqualToConstant: 210).isActive = true
            button.backgroundColor = theme.buttonBackground
            button.layer.borderColor = theme.pathBorder.cgColor
            button.layer.borderWidth = 1
            button.layer.cornerRadius = 6
            button.contentEdgeInsets = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
            button.accessibilityLabel = "\(location.category): \(title)"
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
#if targetEnvironment(macCatalyst)
        openDesktopFile(entry)
#else
        if entry.mimeType().hasPrefix("image/") {
            let folderEntries = activePane?.visibleEntries ?? [entry]
            openImageViewer(entry, folderEntries: folderEntries)
            return
        }
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
#endif
    }

#if targetEnvironment(macCatalyst)
    func openDesktopFile(_ entry: FileEntry, chooseApplication: Bool = false) {
        guard let bridge = DesktopBridge.shared else {
            updateGlobalStatus(L10n.get("desktop_bridge_unavailable"))
            return
        }
        // Physical files stay at their original URL. The standard application
        // and macOS handle their content/download, just as when Finder opens them.
        prepareDocument(entry, coordinatePhysicalFile: false) { [weak self] url in
            guard let self else { return }
            let completion: (Bool, NSError?) -> Void = { [weak self] opened, error in
                guard let self else { return }
                if let error {
                    let alert = UIAlertController(title: L10n.get("file_open_failed"),
                        message: "\(entry.name())\n\(error.localizedDescription)", preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: L10n.get("open_with"), style: .default) { _ in
                        self.openDesktopFile(entry, chooseApplication: true)
                    })
                    alert.addAction(UIAlertAction(title: L10n.get("cancel"), style: .cancel))
                    if self.presentedViewController == nil { self.present(alert, animated: true) }
                    self.updateGlobalStatus(String(format: L10n.get("error_prefix"), error.localizedDescription))
                } else if opened {
                    self.updateGlobalStatus(String(format: L10n.get("file_handed_to_macos"), entry.name()))
                }
            }
            if chooseApplication {
                bridge.chooseApplication(for: url, title: L10n.get("open_with"), completion: completion)
            } else {
                bridge.openFile(url, application: nil, completion: completion)
            }
        }
    }
#endif

    func previewFile(_ entry: FileEntry) {
#if targetEnvironment(macCatalyst)
        let mime = entry.mimeType()
        if ["image/", "video/", "audio/"].contains(where: { mime.hasPrefix($0) }) {
            guard presentedViewController == nil else { return }
            openImageViewer(entry, folderEntries: activePane?.visibleEntries ?? [entry])
            return
        }
#endif
        prepareDocument(entry, coordinatePhysicalFile: true) { [weak self] url in
            guard let self else { return }
#if targetEnvironment(macCatalyst)
            let canPreview = QLPreviewController.canPreviewItem(url as NSURL)
#else
            let canPreview = QLPreviewController.canPreview(url as NSURL)
#endif
            guard canPreview else {
                self.updateGlobalStatus(L10n.get("preview_unavailable"))
                return
            }
            var candidates = [url]
#if targetEnvironment(macCatalyst)
            if entry.zipPath == nil {
                candidates = (self.activePane?.visibleEntries ?? []).filter {
                    !$0.isDirectoryLike() && $0.zipPath == nil && QLPreviewController.canPreviewItem($0.url as NSURL)
                }.map { $0.url }
                if !candidates.contains(url) { candidates = [url] }
            }
#endif
            self.documentPreviewURLs = candidates
            let preview = QLPreviewController()
            preview.dataSource = self
            preview.currentPreviewItemIndex = candidates.firstIndex(of: url) ?? 0
            self.present(preview, animated: true)
        }
    }

    private func prepareDocument(_ entry: FileEntry, coordinatePhysicalFile: Bool,
                                 completion: @escaping (URL) -> Void) {
        guard !documentPreparationPending, presentedViewController == nil else { return }
        documentPreparationPending = true
        documentPreparationGeneration += 1
        let generation = documentPreparationGeneration
        let coordinator = NSFileCoordinator()
        updateGlobalStatus(L10n.get("file_opening"))
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<URL, Error> = Result {
                if entry.zipPath == nil && !coordinatePhysicalFile { return entry.url }
                var accessError: NSError?
                var prepared: Result<URL, Error>?
                coordinator.coordinate(readingItemAt: entry.url, options: .withoutChanges,
                    error: &accessError) { url in
                    prepared = Result { try entry.materializedURLForOpening(sourceURL: url) }
                }
                if let accessError { throw accessError }
                guard let prepared else { throw CocoaError(.fileReadUnknown) }
                return try prepared.get()
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.documentPreparationGeneration == generation else { return }
                self.documentPreparationPending = false
                switch result {
                case .success(let url): completion(url)
                case .failure(let error):
                    self.updateGlobalStatus(String(format: L10n.get("error_prefix"), error.localizedDescription))
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.documentPreparationPending,
                  self.documentPreparationGeneration == generation else { return }
            self.documentPreparationGeneration += 1
            self.documentPreparationPending = false
            coordinator.cancel()
            self.updateGlobalStatus(L10n.get("file_open_slow"))
        }
    }

    func openImageViewer(_ selected: FileEntry, folderEntries: [FileEntry]) {
#if targetEnvironment(macCatalyst)
        var images = folderEntries.filter { entry in
            !entry.isDirectoryLike() && ["image/", "video/", "audio/"].contains(where: { entry.mimeType().hasPrefix($0) })
        }
#else
        var images = folderEntries.filter { !$0.isDirectoryLike() && $0.mimeType().hasPrefix("image/") }
#endif
        var selectedIndex = images.firstIndex(where: { $0.key() == selected.key() })
        if selectedIndex == nil {
            images.append(selected)
            selectedIndex = images.indices.last
        }
        guard let index = selectedIndex else { return }
        let viewer = ImageViewerViewController(entries: images, initialIndex: index)
        viewer.modalPresentationStyle = .fullScreen
        viewer.modalTransitionStyle = .crossDissolve
        present(viewer, animated: true)
    }

    // Folder open events are kept in-app; never forward them back to the default
    // handler (which may be this app), avoiding a Launch Services recursion.
    func openIncomingFolder(_ url: URL) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        guard HostFileSystem.isDirectory(url),
              (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) != true,
              let pane = activePane ?? leftPane else {
            if scoped { url.stopAccessingSecurityScopedResource() }
            return false
        }
        if scoped { securityScopedURLs.append(url) }
        openLocation(url, in: pane)
        return true
    }

#if targetEnvironment(macCatalyst)
    @objc private func showFolderDefaultPreferences() {
        presentFolderDefaultChoice(firstRun: false)
    }

    private func presentFolderDefaultChoice(firstRun: Bool) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: L10n.get("folder_default_title"),
            message: L10n.get("folder_default_message"), preferredStyle: .alert)
        func rememberChoice() {
            UserDefaults.standard.set(true, forKey: "mac_folder_default_prompt_v1")
        }
        alert.addAction(UIAlertAction(title: L10n.get("folder_default_accept"), style: .default) { _ in
            rememberChoice()
            self.dismiss(animated: true) { self.changeFolderDefault(to: Bundle.main.bundleURL) }
        })
        if !firstRun {
            alert.addAction(UIAlertAction(title: L10n.get("folder_default_finder"), style: .default) { _ in
                self.dismiss(animated: true) {
                    self.changeFolderDefault(to: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))
                }
            })
        }
        alert.addAction(UIAlertAction(title: L10n.get("later"), style: .cancel) { _ in
            rememberChoice()
            if firstRun { self.dismiss(animated: true) { self.maybeShowFirstRunHelp() } }
        })
        present(alert, animated: true)
    }

    private func changeFolderDefault(to application: URL) {
        guard let bridge = DesktopBridge.shared else {
            showScrollableDialog(title: L10n.get("folder_default_title"), message: L10n.get("desktop_bridge_unavailable"))
            return
        }
        bridge.setFolderApplication(application) { [weak self] error in
            guard let self else { return }
            self.showScrollableDialog(title: L10n.get("folder_default_title"),
                message: error?.localizedDescription ?? L10n.get("folder_default_success"))
        }
    }
#endif

    func maybeShowFirstRunHelp() {
#if targetEnvironment(macCatalyst)
        if !UserDefaults.standard.bool(forKey: "mac_folder_default_prompt_v1") {
            DispatchQueue.main.async { self.presentFolderDefaultChoice(firstRun: true) }
            return
        }
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
#if !targetEnvironment(macCatalyst)
        DispatchQueue.main.async { [weak self] in self?.presentStorageSources() }
#endif
    }

    private func maybeShowGeneralFirstRunHelp() {
        let key = "onboarding_shown"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        DispatchQueue.main.async { self.showHelpDialog() }
    }
    
    func selectedPanes() -> [CommanderPane] {
#if targetEnvironment(macCatalyst)
        if activePane?.onlineNavigation != nil { return [] }
#endif
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

    func showProgress(_ message: String, progress: Int, cancellable: Bool = false, indeterminate: Bool = false, onCancel: (() -> Void)? = nil) {
        operationInProgress = true
        operationCancellation.reset()
        view.subviews.forEach { $0.isUserInteractionEnabled = false }
        if cancellable {
            let button = miniButton(label: L10n.get("cancel"))
            button.accessibilityIdentifier = "CancelFileOperation"
            button.addAction(UIAction { [weak self, weak button] _ in
                self?.operationCancellation.cancel()
                self?.operationReadCoordinator?.cancel()
                onCancel?()
                button?.isEnabled = false
            }, for: .touchUpInside)
            view.addSubview(button)
            NSLayoutConstraint.activate([
                button.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
                button.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8)])
            cancelOperationButton = button
        }
        progressText.text = message
        progressBar.isHidden = indeterminate
        if indeterminate { progressActivity.startAnimating() } else { progressActivity.stopAnimating() }
        progressBar.progress = Float(progress) / 100
        updateGlobalStatus(message)
    }

    func updateProgress(progress: Int) {
        progressActivity.stopAnimating()
        progressBar.isHidden = false
        progressBar.progress = Float(max(0, min(100, progress))) / 100
    }

    func finishProgress(_ message: String) {
        progressActivity.stopAnimating()
        operationReadCoordinator = nil
        operationInProgress = false
        cancelOperationButton?.removeFromSuperview()
        cancelOperationButton = nil
        view.subviews.forEach { $0.isUserInteractionEnabled = true }
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
        case .rename(let record): return String(format: L10n.get("renamed_item"), record.destination.lastPathComponent)
        case .cloud(let record): return record.action
        }
    }
    
    @objc func confirmDeleteSelection() {
#if targetEnvironment(macCatalyst)
        if let browser = activePane?.onlineBrowser { browser.deleteOnlineSelection(); return }
#endif
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
            var records: [FileUndoRecord] = []
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
                        records.append(FileUndoRecord(source: url, destination: trashedURL, replacedBackup: nil))
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
                        records.append(FileUndoRecord(source: url, destination: trashedURL, replacedBackup: nil))
#endif
                    } else {
                        // Keep undo data on the source volume, not in purgeable /tmp.
                        let backupRoot = url.deletingLastPathComponent()
                            .appendingPathComponent(".OpenCommanderUndo-\(UUID().uuidString)", isDirectory: true)
                        try fm.createDirectory(at: backupRoot, withIntermediateDirectories: false)
                        let backup = self.uniqueURL(in: backupRoot, name: url.lastPathComponent)
                        try fm.moveItem(at: url, to: backup)
                        records.append(FileUndoRecord(source: url, destination: backup, replacedBackup: nil))
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
    
    @objc func showCommanderToolsMenu() {
        guard !operationInProgress, presentedViewController == nil else { return }
        let alert = UIAlertController(title: L10n.get("commander_tools"), message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.get("commander_compare"), style: .default) { _ in self.showCommanderCompare() })
        alert.addAction(UIAlertAction(title: L10n.get("commander_rename"), style: .default) { _ in self.showCommanderRename() })
        alert.addAction(UIAlertAction(title: L10n.get("cancel"), style: .cancel))
        present(alert, animated: true)
    }
    @objc func showCommanderSearch() { showCommanderTool(.search) }
    @objc func showCommanderCompare() { showCommanderTool(.compare) }
    @objc func showCommanderRename() { showCommanderTool(.rename) }
    private func showCommanderTool(_ mode: CommanderToolsController.Mode) {
        guard !operationInProgress, let pane = activePane else { return }
#if targetEnvironment(macCatalyst)
        guard pane.onlineBrowser == nil, mode != .compare || (leftPane.onlineBrowser == nil && rightPane.onlineBrowser == nil) else {
            updateGlobalStatus(L10n.get("commander_local_only")); return
        }
#endif
        guard pane.currentDirectory.isPhysical(), mode != .compare || (leftPane.currentDirectory.isPhysical() && rightPane.currentDirectory.isPhysical()) else {
            updateGlobalStatus(L10n.get("commander_local_only")); return
        }
        let selection = pane.selectedEntries().sorted { $0.name().localizedStandardCompare($1.name()) == .orderedAscending }
        if mode == .rename && (selection.isEmpty || !selection.allSatisfy { $0.isPhysical() }) {
            updateGlobalStatus(L10n.get("commander_select")); return
        }
        let controller = CommanderToolsController(mode: mode,
            root: mode == .compare ? leftPane.currentDirectory.url : pane.currentDirectory.url,
            other: rightPane.currentDirectory.url, selected: selection.map(\.url),
            hidden: UserDefaults.standard.bool(forKey: "show_hidden_files"))
        controller.overrideUserInterfaceStyle = darkMode ? .dark : .light
        controller.modalPresentationStyle = .formSheet
        controller.preferredContentSize = CGSize(width: 940, height: 720)
        controller.onOpen = { [weak self, weak pane] url in
            guard let self, let pane else { return }
            pane.openDirectory(FileEntry(url: url.deletingLastPathComponent(), parent: nil))
            self.updateGlobalStatus(url.lastPathComponent)
        }
        controller.onRename = { [weak self, weak pane] records in
            guard let self, let pane else { return }
            if !records.isEmpty { self.operationHistory.append(.move(files: records)) }
            self.refreshAllPanes(clearSelectionIn: [pane])
        }
        // Menu actions dismiss their alert before presenting the tool sheet.
        if let presented = presentedViewController {
            presented.dismiss(animated: false) { self.present(controller, animated: true) }
        } else { present(controller, animated: true) }
    }

    @objc func showRenameDialog() {
#if targetEnvironment(macCatalyst)
        if let browser = activePane?.onlineBrowser { browser.renameOnlineSelection(); return }
#endif
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
                let record = FileUndoRecord(source: url, destination: newUrl, replacedBackup: nil)
                DispatchQueue.main.async {
                    self.operationHistory.append(.rename(record: record))
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
#if targetEnvironment(macCatalyst)
        let targetBrowser = [leftPane, rightPane].compactMap { $0 }.first { $0.currentDirectory === targetDirectory }?.onlineBrowser
        if let source = sourcePane.onlineBrowser {
            if let targetBrowser { targetBrowser.receiveOnline(source.selection, move: moveMode) }
            else if targetDirectory.canWriteDirectory() { source.exportOnline(source.selection, to: targetDirectory.url, move: moveMode) }
            return
        }
        if let targetBrowser {
            let entries = sourcePane.selectedEntries()
            guard entries.allSatisfy({ $0.isPhysical() }) else { updateGlobalStatus(L10n.get("zip_read_only")); return }
            targetBrowser.receiveLocal(entries.map(\.url), move: moveMode); return
        }
#endif
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
#if targetEnvironment(macCatalyst)
        if sourcePane?.onlineNavigation != nil || [leftPane, rightPane].contains(where: {
            $0?.onlineNavigation != nil && $0?.currentDirectory === targetDirectory
        }) {
            updateGlobalStatus("OneDrive online: Aktionen → Datei hochladen / Herunterladen")
            completion(); return
        }
#endif
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
        showProgress(String(format: L10n.get(move ? "moving_items" : "copying_items"), sources.count), progress: 0, cancellable: true)
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let targetURL = targetDirectory.url
            var movedFiles: [FileUndoRecord] = []
            var copiedFiles: [FileUndoRecord] = []
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
                    try self.operationCancellation.check()
                    if SafeFileOperations.exists(preferred) {
                        if replace && move {
                            let backupRoot = targetURL.appendingPathComponent(".OpenCommanderUndo-\(UUID().uuidString)", isDirectory: true)
                            try fm.createDirectory(at: backupRoot, withIntermediateDirectories: false)
                            let backup = backupRoot.appendingPathComponent(preferred.lastPathComponent)
                            try fm.moveItem(at: preferred, to: backup)
                            replacedBackup = backup
                        } else if !replace {
                            destination = self.uniqueURL(in: targetURL, name: preferred.lastPathComponent)
                        }
                    }
                    if move {
                        try fm.moveItem(at: sourceURL, to: destination)
                        movedFiles.append(FileUndoRecord(source: sourceURL, destination: destination, replacedBackup: replacedBackup))
                    } else {
                        replacedBackup = try SafeFileOperations.copyReplacing(
                            source: sourceURL, destination: destination, replace: replace,
                            copy: self.operationCancellation.copy)
                        copiedFiles.append(FileUndoRecord(source: sourceURL, destination: destination, replacedBackup: replacedBackup))
                    }
                } catch {
                    failure = error
                    if let replacedBackup {
                        do {
                            guard !SafeFileOperations.exists(preferred) else { throw SafeFileOperations.conflict(preferred) }
                            try fm.moveItem(at: replacedBackup, to: preferred)
                        } catch {
                            failure = NSError(domain: "OpenCommander.FileSafety", code: 2,
                                              userInfo: [NSLocalizedDescriptionKey:
                                                L10n.get("recovery_retained", replacedBackup.path) + "\n" + error.localizedDescription])
                        }
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
    @objc func extractSelection() {
#if targetEnvironment(macCatalyst)
        if let browser = activePane?.onlineBrowser { browser.extractOnlineSelection(); return }
#endif
#if targetEnvironment(macCatalyst)
        if activePane?.onlineNavigation != nil { return }
#endif
        guard !operationInProgress, let pane = activePane else { return }
        let selected = pane.selectedEntries()
        let source = selected.first ?? pane.currentDirectory!
        let archiveURL = source.url
        guard source.zipPath != nil || archiveURL.pathExtension.lowercased() == "zip" else {
            updateGlobalStatus(L10n.get("extract_archive")); return
        }
        let target = pane === leftPane ? rightPane! : leftPane!
        guard target.currentDirectory.canWriteDirectory() else {
            updateGlobalStatus(L10n.get("target_not_writable")); return
        }
        let targetURL = target.currentDirectory.url
        let prefixes = selected.compactMap { $0.zipPath }
        let currentPrefix = pane.currentDirectory.zipPath ?? ""
        showProgress(L10n.get("extract_archive"), progress: 0, cancellable: true)
        let coordinator = NSFileCoordinator()
        operationReadCoordinator = coordinator
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let staging = targetURL.appendingPathComponent(".OpenCommanderExtract-\(UUID().uuidString)")
            var record: FileUndoRecord?
            var failure: Error?
            do {
                func extractCoordinated(_ archiveURL: URL) throws {
                guard let archive = Archive(url: archiveURL, accessMode: .read) else { throw CocoaError(.fileReadCorruptFile) }
                var limits = SafeArchiveLimits()
                var entries: [Entry] = []
                for item in archive {
                    try self.operationCancellation.check()
                    try limits.include(path: item.path, size: UInt64(item.uncompressedSize), symbolicLink: item.type == .symlink)
                    let matches = !prefixes.isEmpty ? prefixes.contains { item.path == $0 || item.path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") } :
                        (currentPrefix.isEmpty || item.path.hasPrefix(currentPrefix))
                    if matches { entries.append(item) }
                }
                guard !entries.isEmpty else { throw CocoaError(.fileReadNoSuchFile) }
                try fm.createDirectory(at: staging, withIntermediateDirectories: false)
                defer { try? fm.removeItem(at: staging) }
                for (index, item) in entries.enumerated() {
                    try self.operationCancellation.check()
                    let destination = staging.appendingPathComponent(item.path)
                    guard destination.standardizedFileURL.path.hasPrefix(staging.path + "/") else { throw CocoaError(.fileReadCorruptFile) }
                    if item.type == .directory {
                        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                    } else {
                        guard !SafeFileOperations.exists(destination) else { throw SafeFileOperations.conflict(destination) }
                        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                        let handle = fm.createFile(atPath: destination.path, contents: nil)
                        guard handle else { throw CocoaError(.fileWriteUnknown) }
                        let output = try FileHandle(forWritingTo: destination)
                        defer { try? output.close() }
                        var written: UInt64 = 0
                        let checksum = try archive.extract(item) { data in
                            try self.operationCancellation.check()
                            guard UInt64(data.count) <= item.uncompressedSize - written else { throw CocoaError(.fileReadCorruptFile) }
                            written += UInt64(data.count)
                            try output.write(contentsOf: data)
                        }
                        guard checksum == item.checksum, written == item.uncompressedSize else { throw CocoaError(.fileReadCorruptFile) }
                        if let modified = item.fileAttributes[.modificationDate] as? Date {
                            try fm.setAttributes([.modificationDate: modified], ofItemAtPath: destination.path)
                        }
                    }
                    DispatchQueue.main.async { self.updateProgress(progress: (index + 1) * 100 / entries.count) }
                }
                let published = self.uniqueURL(in: targetURL, name: archiveURL.deletingPathExtension().lastPathComponent)
                try self.operationCancellation.check()
                try fm.moveItem(at: staging, to: published)
                record = FileUndoRecord(source: archiveURL, destination: published, replacedBackup: nil)
                }
                var coordinationError: NSError?
                var result: Result<Void, Error>?
                coordinator.coordinate(readingItemAt: archiveURL, options: .withoutChanges, error: &coordinationError) { readable in
                    result = Result { try extractCoordinated(readable) }
                }
                if let coordinationError { throw coordinationError }
                guard let result else { throw CocoaError(.fileReadUnknown) }
                try result.get()
            } catch { failure = error }
            DispatchQueue.main.async {
                if let record { self.operationHistory.append(.copy(files: [record])) }
                self.refreshAllPanes(clearSelectionIn: [])
                self.finishProgress(failure?.localizedDescription ?? L10n.get("extract_complete"))
            }
        }
    }

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
        guard !operationInProgress, presentedViewController == nil else { return }
#if targetEnvironment(macCatalyst)
        if let browser = activePane?.onlineBrowser { browser.zipOnlineSelection(); return }
#endif
        let pane = activePane ?? leftPane
        let sources = pane?.selectedEntries() ?? []
        if sources.isEmpty {
            updateGlobalStatus(L10n.get("zip_no_selection"))
            return
        }
        guard sources.allSatisfy({ $0.isPhysical() }) else {
            updateGlobalStatus(L10n.get("zip_read_only"))
            return
        }
#if targetEnvironment(macCatalyst)
        guard let bridge = DesktopBridge.shared else { return }
        bridge.chooseArchiveDestination(name: archiveName(for: sources),
            directory: pane?.currentDirectory.url ?? HostFileSystem.downloadsDirectory,
            title: L10n.get("zip_save_title")) { [weak self] destination in
            guard let self, let destination else { return }
            guard !sources.contains(where: { $0.url.standardizedFileURL == destination.standardizedFileURL }) else {
                self.updateGlobalStatus(L10n.get("zip_source_destination")); return
            }
            self.performZipCreation(sources: sources, pane: pane, destination: destination)
        }
#else
        performZipCreation(sources: sources, pane: pane, destination: nil)
#endif
    }

    private func performZipCreation(sources: [FileEntry], pane: CommanderPane?, destination: URL?) {
        let panes = pane.map { [$0] } ?? []
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
                var limits = SafeArchiveLimits()
                while let entry = pending.popLast() {
                    let metadata = try HostFileSystem.coordinatedRead(at: entry.url) { url -> (URLResourceValues, [String]) in
                        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
                        let children = values.isDirectory == true && values.isSymbolicLink != true
                            ? try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).map(\.lastPathComponent) : []
                        return (values, children)
                    }
                    try limits.include(path: entry.path, size: UInt64(max(0, metadata.0.isDirectory == true ? 0 : (metadata.0.fileSize ?? 0))),
                        symbolicLink: metadata.0.isSymbolicLink == true)
                    entries.append(entry)
                    if metadata.0.isDirectory == true {
                        for name in metadata.1 {
                            // Build archive paths from names, never by subtracting
                            // /var vs /private/var filesystem URL prefixes.
                            pending.append((entry.path + "/" + name, entry.url.appendingPathComponent(name)))
                        }
                    }
                }
                try fm.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
                let stagedArchive = stagingDirectory.appendingPathComponent("archive.zip")
                try autoreleasepool {
                    let archive = try Archive(url: stagedArchive, accessMode: .create, pathEncoding: nil)
                    for (index, entry) in entries.enumerated() {
                        // Keep the actual source URL separate from the ZIP entry name.
                        try HostFileSystem.coordinatedRead(at: entry.url) { url in
                            try archive.addEntry(with: entry.path, fileURL: url, compressionMethod: .deflate)
                        }
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
                var replacedBackup: URL?
                if let destination {
                    var coordinationError: NSError?
                    var result: Result<URL?, Error>?
                    NSFileCoordinator().coordinate(writingItemAt: destination, options: .forReplacing, error: &coordinationError) { url in
                        result = Result { try SafeFileOperations.copyReplacing(source: stagedArchive, destination: url,
                            replace: SafeFileOperations.exists(url)) }
                    }
                    if let coordinationError { throw coordinationError }
                    guard let result else { throw CocoaError(.fileWriteUnknown) }
                    replacedBackup = try result.get()
                    archiveURL = destination
                    usedDocuments = false
                } else { do {
                    archiveURL = try publish(in: parentDir)
                    usedDocuments = false
                } catch {
                    guard isWritePermissionError(error as NSError),
                          parentDir.resolvingSymlinksInPath() != documents.resolvingSymlinksInPath() else { throw error }
                    // iOS forbids creating Documents.zip beside Documents at the
                    // container root. Publish it inside the writable Documents folder.
                    archiveURL = try publish(in: documents)
                    usedDocuments = true
                } }
                let record = FileUndoRecord(source: archiveURL, destination: archiveURL, replacedBackup: replacedBackup)
                DispatchQueue.main.async {
                    self.operationHistory.append(.zip(record: record))
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
#if targetEnvironment(macCatalyst)
        if let browser = activePane?.onlineBrowser { browser.undoOnlineOperation(); return }
#endif
        if let index = operationHistory.lastIndex(where: { if case .cloud = $0 { return false }; return true }) {
            undoOperation(at: index)
        } else { updateGlobalStatus(L10n.get("undo_empty")) }
    }

    private func undoOperation(at index: Int) {
        guard !operationInProgress else { return }
        guard operationHistory.indices.contains(index) else {
            updateGlobalStatus(L10n.get("undo_empty"))
            return
        }
        let lastOp = operationHistory[index]
        if case .cloud = lastOp { return }
        showProgress(String(format: L10n.get("undo_progress"), operationLabel(lastOp)), progress: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                switch lastOp {
                case .delete(let files):
                    for file in files.reversed() { try file.undo(move: true) }
                case .move(let files):
                    for file in files.reversed() { try file.undo(move: true) }
                case .copy(let files):
                    for file in files.reversed() { try file.undo(move: false) }
                case .zip(let record): try record.undo(move: false)
                case .rename(let record): try record.undo(move: true)
                case .cloud: break
                }
                
                DispatchQueue.main.async {
                    self.operationHistory.remove(at: index)
                    self.refreshAllPanes(clearSelectionIn: [])
                    self.finishProgress(String(format: L10n.get("undo_done"), 1))
                }
            } catch {
                DispatchQueue.main.async {
                    switch lastOp {
                    case .delete(let files):
                        files.filter { !$0.completed }.forEach { $0.setHistoryError(error) }
                        self.operationHistory[index] = .delete(files: files.filter { !$0.completed })
                    case .move(let files):
                        files.filter { !$0.completed }.forEach { $0.setHistoryError(error) }
                        self.operationHistory[index] = .move(files: files.filter { !$0.completed })
                    case .copy(let files):
                        files.filter { !$0.completed }.forEach { $0.setHistoryError(error) }
                        self.operationHistory[index] = .copy(files: files.filter { !$0.completed })
                    case .zip(let record), .rename(let record): record.setHistoryError(error)
                    case .cloud: break
                    }
                    // Also persist failed single-item undo/partial retry state.
                    if let data = try? JSONEncoder().encode(self.operationHistory) {
                        UserDefaults.standard.set(data, forKey: "operation_history_v1")
                    }
                    self.refreshAllPanes(clearSelectionIn: [])
                    self.finishProgress(String(format: L10n.get("undo_failed"), HistoryFailure(error).message))
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
        sections.append(L10n.get("help_open_macos"))
        sections.append(L10n.get("help_cloud_macos"))
        sections.append(L10n.get("help_desktop_parity"))
        sections.append(L10n.get("commander_help"))
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
        for lang in Self.languageChoices {
            alert.addAction(UIAlertAction(title: lang.0, style: .default, handler: { _ in
                self.applyLanguage(lang.1)
            }))
        }
        alert.addAction(UIAlertAction(title: L10n.get("cancel"), style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = self.languageButton
            popover.sourceRect = self.languageButton.bounds
        }
        self.present(alert, animated: true)
    }

    static var languageChoices: [(String, String)] {
        [
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
    }

    func applyLanguage(_ code: String) {
        L10n.currentLanguage = L10n.resolvedLanguage(code.isEmpty ? Locale.current.identifier : code)
        UserDefaults.standard.set(code, forKey: "language")
        rebuildApp()
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
        stack.spacing = 8
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
        let height = historyPanel.heightAnchor.constraint(equalToConstant: operationHistory.isEmpty ? 36 : 220)
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
                case .zip(let record): title = String(format: L10n.get("zip_created"), record.destination.lastPathComponent)
                case .rename(let record): title = String(format: L10n.get("renamed_item"), record.destination.lastPathComponent)
                case .cloud(let record): title = "OneDrive online · " + record.action
                }
                let records: [FileUndoRecord]
                switch op {
                case .delete(let values), .move(let values), .copy(let values): records = values
                case .zip(let value), .rename(let value): records = [value]
                case .cloud: records = []
                }
                let createdAt: Date?
                let paths: String
                let canUndo: Bool
                if case .cloud(let record) = op {
                    createdAt = record.createdAt
                    paths = record.source + " → " + record.destination
                    canUndo = false // Audit entries do not contain safe remote undo data.
                } else {
                    createdAt = records.first?.createdAt
                    paths = records.map { $0.source.path + " → " + $0.destination.path }.joined(separator: "\n")
                    canUndo = records.contains { !$0.completed }
                }
                let card = UIView()
                card.backgroundColor = theme.pathBackground
                card.layer.cornerRadius = 8
                card.layer.borderWidth = 1
                card.layer.borderColor = theme.panelBorder.cgColor
                card.accessibilityIdentifier = "HistoryEntry-\(index)"
                let compact = view.bounds.width < 600
                let row = UIStackView(); row.axis = compact ? .vertical : .horizontal
                row.spacing = 12; row.alignment = compact ? .fill : .center
                row.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(row)
                NSLayoutConstraint.activate([
                    row.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
                    row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
                    row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
                    row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10)])
                let content = UIStackView(); content.axis = .vertical; content.spacing = 5
                let heading = UIStackView(); heading.spacing = 5; heading.axis = compact ? .vertical : .horizontal
                let name = UILabel(); name.text = title; name.font = .systemFont(ofSize: 13, weight: .semibold)
                name.textColor = theme.primaryText; name.lineBreakMode = .byTruncatingTail
                let timestamp = UILabel()
                timestamp.text = createdAt.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .medium) } ?? "—"
                timestamp.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
                timestamp.textColor = theme.secondaryText
                timestamp.accessibilityIdentifier = "HistoryTime-\(index)"
                timestamp.setContentCompressionResistancePriority(.required, for: .horizontal)
                timestamp.setContentHuggingPriority(.required, for: .horizontal)
                heading.addArrangedSubview(name); heading.addArrangedSubview(timestamp); content.addArrangedSubview(heading)
                let location = UILabel(); location.text = paths; location.numberOfLines = 2
                location.lineBreakMode = .byTruncatingMiddle; location.font = .systemFont(ofSize: 12)
                location.textColor = theme.secondaryText; content.addArrangedSubview(location)
                if let error = records.compactMap(\.historyErrorMessage).first {
                    let warning = UILabel(); warning.text = "⚠ " + error; warning.numberOfLines = 2
                    warning.font = .systemFont(ofSize: 12); warning.textColor = .systemRed
                    content.addArrangedSubview(warning)
                }
                if !canUndo {
                    let hint = UILabel(); hint.text = L10n.get("history_undo_unavailable")
                    hint.font = .systemFont(ofSize: 11); hint.textColor = theme.secondaryText
                    content.addArrangedSubview(hint)
                }
                row.addArrangedSubview(content)
                let actions = UIStackView(); actions.spacing = 12; actions.alignment = .center
                if compact { actions.addArrangedSubview(UIView()) }
                let details = UIButton(type: .system)
                details.setImage(UIImage(systemName: "info.circle"), for: .normal)
                details.accessibilityLabel = L10n.get("history_details")
                details.accessibilityIdentifier = "HistoryDetails-\(index)"
                details.widthAnchor.constraint(equalToConstant: 36).isActive = true
                details.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
                let backupPaths = records.compactMap { $0.replacedBackup?.path }
                let detailText = [timestamp.text ?? "", paths] + backupPaths + records.compactMap(\.historyErrorMessage)
                details.addAction(UIAction { [weak self] _ in
                    guard let self, !self.operationInProgress, self.presentedViewController == nil else { return }
                    self.showScrollableDialog(title: title, message: detailText.joined(separator: "\n\n"))
                }, for: .touchUpInside)
                actions.addArrangedSubview(details)
                let undo = miniButton(label: "↶ " + L10n.get("undo"))
                undo.accessibilityIdentifier = "HistoryUndo-\(index)"
                undo.isEnabled = canUndo && !operationInProgress
                undo.alpha = canUndo ? 1 : 0.45
                undo.widthAnchor.constraint(equalToConstant: 140).isActive = true
                undo.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
                undo.setContentCompressionResistancePriority(.required, for: .horizontal)
                undo.addAction(UIAction { [weak self] _ in self?.undoOperation(at: index) }, for: .touchUpInside)
                actions.addArrangedSubview(undo)
                row.addArrangedSubview(actions)
                stack.addArrangedSubview(card)
            }
        }
    }

}

extension ViewController: UIDocumentInteractionControllerDelegate {
    func documentInteractionControllerViewControllerForPreview(_ controller: UIDocumentInteractionController) -> UIViewController {
        self
    }
}

extension ViewController: QLPreviewControllerDataSource {
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        documentPreviewURLs.count
    }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        documentPreviewURLs[index] as NSURL
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
            let name = location.isLocalArchive ? "\(location.name) — \(L10n.get("cloud_local_archive"))" : location.name
            locations.append(("\(prefix): \(name)", location.url))
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
        presentStorageSources()
#endif
    }

#if !targetEnvironment(macCatalyst)
    private func presentStorageSources() {
        guard presentedViewController == nil else { return }
        let sources = StorageSourcesController(style: .insetGrouped)
        sources.chooseFolder = { [weak self] in self?.presentFolderPicker() }
        sources.localFiles = { [weak self] in
            guard let self else { return }
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            self.openLocation(documents, in: self.activePane ?? self.leftPane, persistPath: false)
        }
        sources.importedFiles = { [weak self] in self?.openLocalMediaFolder() }
        sources.importMedia = { [weak self] in self?.presentPhotoVideoPicker() }
        let stored = UserDefaults.standard.dictionary(forKey: "media_connected_folders") as? [String: Data] ?? [:]
        let localDocuments = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].standardizedFileURL.resolvingSymlinksInPath()
        var saved: [String: Data] = [:]
        for (path, data) in stored {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) {
                let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
                // Reinstallation can change the container path. Keep one connection
                // per resolved folder; app Documents already has its own source row.
                if canonical != localDocuments { saved[canonical.path] = data }
            } else {
                // Preserve offline provider connections so the user can reconnect.
                saved[path] = data
            }
        }
        for pane in [leftPane, rightPane].compactMap({ $0 }) {
            if let url = restoreFolderLocation(forPane: pane.title),
               let data = UserDefaults.standard.data(forKey: bookmarkKey(forPane: pane.title)) {
                let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
                if canonical != localDocuments { saved[canonical.path] = data }
            }
        }
        UserDefaults.standard.set(saved, forKey: "media_connected_folders")
        for (path, data) in saved.sorted(by: { $0.key.localizedStandardCompare($1.key) == .orderedAscending }) {
            sources.locations.append(.init(title: URL(fileURLWithPath: path).lastPathComponent, open: { [weak self] in
                guard let self else { return }
                do {
                    var stale = false
                    let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
                    let scoped = url.startAccessingSecurityScopedResource()
                    if scoped {
                        if self.securityScopedURLs.contains(url) { url.stopAccessingSecurityScopedResource() }
                        else { self.securityScopedURLs.append(url) }
                    }
                    _ = try HostFileSystem.directoryContents(at: url, showHidden: false)
                    if stale, let renewed = try? url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil) {
                        var folders = UserDefaults.standard.dictionary(forKey: "media_connected_folders") as? [String: Data] ?? [:]
                        folders[path] = renewed; UserDefaults.standard.set(folders, forKey: "media_connected_folders")
                    }
                    self.saveFolderBookmark(url, forPane: (self.activePane ?? self.leftPane).title)
                    self.openLocation(url, in: self.activePane ?? self.leftPane, persistPath: false)
                } catch { self.showFolderAccessFailure(error) }
            }, forget: {
                var folders = UserDefaults.standard.dictionary(forKey: "media_connected_folders") as? [String: Data] ?? [:]
                folders.removeValue(forKey: path); UserDefaults.standard.set(folders, forKey: "media_connected_folders")
                for title in ["1", "2"] {
                    if UserDefaults.standard.data(forKey: "folder_bookmark_pane_\(title)") == data {
                        UserDefaults.standard.removeObject(forKey: "folder_bookmark_pane_\(title)")
                    }
                }
            }))
        }
        let navigation = UINavigationController(rootViewController: sources)
        navigation.modalPresentationStyle = .fullScreen
        present(navigation, animated: true)
    }

    private func localMediaFolderURL() throws -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let media = documents.appendingPathComponent("Media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        return media
    }

    private func openLocalMediaFolder() {
        do {
            let media = try localMediaFolderURL()
            openLocation(media, in: activePane ?? leftPane, persistPath: false)
        } catch {
            updateGlobalStatus(String(format: L10n.get("error_prefix"), error.localizedDescription))
        }
    }

    private func presentPhotoVideoPicker() {
        guard !mediaImportInProgress else {
            updateGlobalStatus(L10n.get("drop_busy"))
            return
        }
        mediaImportPane = activePane ?? leftPane
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .any(of: [.images, .videos])
        configuration.selectionLimit = 0
        configuration.selection = .ordered
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        picker.modalPresentationStyle = .fullScreen
        present(picker, animated: true)
    }

    private func presentMusicPicker() {
        let picker = MPMediaPickerController(mediaTypes: .music)
        picker.delegate = self
        picker.allowsPickingMultipleItems = true
        picker.showsCloudItems = true
        picker.prompt = L10n.get("music_picker_prompt")
        present(picker, animated: true)
    }
#endif

#if targetEnvironment(macCatalyst)
    @objc func showLocationSettings() {
        guard !operationInProgress, presentedViewController == nil, let bridge = DesktopBridge.shared else { return }
        DispatchQueue.global(qos: .utility).async {
            let locations = HostFileSystem.availableStorageLocations()
            var entries = DesktopLocationPreferences.load()
            var details: [String: String] = [:]
            let builtins = [(L10n.get("mac_location"), URL(fileURLWithPath: "/", isDirectory: true)),
                (L10n.get("home_folder"), HostFileSystem.homeDirectory),
                (L10n.get("downloads_folder"), HostFileSystem.downloadsDirectory),
                (L10n.get("location_desktop"), HostFileSystem.desktopDirectory),
                (L10n.get("location_documents"), HostFileSystem.homeDirectory.appendingPathComponent("Documents"))] + locations.map { ($0.displayName, $0.url) }
            for (name, url) in builtins {
                let path = url.resolvingSymlinksInPath().standardizedFileURL.path
                let discovered = locations.first { $0.url.resolvingSymlinksInPath().standardizedFileURL.path == path }
                details[path] = path
                if let discovered, !discovered.visibleByDefault {
                    details[path] = "\(discovered.displayName)\n\(path)"
                }
                if !entries.contains(where: { $0.path == path }) {
                    entries.append(DesktopLocationPreference(path: path, name: name,
                        enabled: discovered?.visibleByDefault ?? true, custom: false))
                } else if let index = entries.firstIndex(where: { $0.path == path }), !entries[index].custom {
                    if discovered?.visibleByDefault == false && entries[index].visibilityConfigured != true {
                        entries[index].enabled = false
                    }
                    if entries[index].name == discovered?.name || discovered?.previousDefaultNames.contains(entries[index].name) == true ||
                        (url == HostFileSystem.homeDirectory && ["Home Folder", "Benutzerordner"].contains(entries[index].name)) {
                        entries[index].name = name
                    }
                }
            }
            let onlinePath = DesktopLocationPreferences.oneDriveOnlinePath
            if !entries.contains(where: { $0.path == onlinePath }) {
                entries.insert(DesktopLocationPreference(path: onlinePath, name: "OneDrive online", enabled: true, custom: false), at: 0)
            }
            details[onlinePath] = L10n.get("onedrive_online_location_help")
            for entry in entries where !entry.custom && entry.path != onlinePath && details[entry.path] == nil {
                details[entry.path] = "\(L10n.get("location_disconnected"))\n\(entry.path)"
            }
            DispatchQueue.main.async {
                guard self.presentedViewController == nil, !self.operationInProgress else { return }
                let settings = DesktopLocationSettingsViewController(entries: entries, changed: { [weak self] entries in
                    DesktopLocationPreferences.save(entries)
                    self?.reloadStorageLocationsBar()
                }, chooseFolder: { completion in
                    bridge.chooseLocation(title: L10n.get("location_add"), completion: completion)
                })
                settings.languageChanged = { [weak self] code in self?.applyLanguage(code) }
                settings.locationDetails = details
                settings.darkMode = self.darkMode
                settings.overrideUserInterfaceStyle = self.darkMode ? .dark : .light
                settings.themeChanged = { [weak self] in self?.toggleDarkModeFromTap() }
                settings.defaultAppRequested = { [weak self] in self?.showFolderDefaultPreferences() }
                settings.legalRequested = { [weak self] in self?.showLegalDialog() }
                settings.oneDriveRequested = { [weak self] in self?.openOneDriveOnline() }
                let navigation = UINavigationController(rootViewController: settings)
                navigation.modalPresentationStyle = .formSheet
                self.present(navigation, animated: true)
            }
        }
    }

    func openSyncApplication(for url: URL) {
        guard let name = HostFileSystem.cloudClientName(for: url), let bridge = DesktopBridge.shared,
              let application = bridge.installedCloudApplications().first(where: { $0["name"] == name }),
              let path = application["path"] else { return }
        bridge.openFile(URL(fileURLWithPath: path), application: nil) { [weak self] _, error in
            self?.updateGlobalStatus(error?.localizedDescription ?? L10n.get("cloud_client_opened"))
        }
    }

    func openOneDriveOnline() {
        guard !operationInProgress, presentedViewController == nil else { return }
        guard let pane = activePane ?? leftPane else { return }
        activePane = pane
        if pane.onlineNavigation != nil { return }
        let browser = OneDriveBrowser()
        browser.commander = self
        browser.paneTitle = pane.title
        browser.onStateChanged = { [weak self] in self?.updateDesktopActions() }
        let navigation = UINavigationController(rootViewController: browser)
        navigation.setNavigationBarHidden(true, animated: false)
        navigation.overrideUserInterfaceStyle = darkMode ? .dark : .light
        browser.onClose = { [weak self, weak pane] in
            pane?.closeOnline()
            self?.activePane = pane
            self?.updateDesktopActions()
        }
        browser.onActivate = { [weak self, weak pane] in
            self?.activePane = pane
            self?.updateDesktopActions()
        }
        addChild(navigation)
        pane.showOnline(navigation)
        navigation.didMove(toParent: self)
        updateDesktopActions()
        updateGlobalStatus("OneDrive online")
    }

    @objc func showConnections() {
        guard !operationInProgress, presentedViewController == nil, let bridge = DesktopBridge.shared else { return }
        updateGlobalStatus(L10n.get("connections_loading"))
        bridge.unmountedVolumes { [weak self] unmounted, discoveryError in
            guard let self, !self.operationInProgress, self.presentedViewController == nil else { return }
            DispatchQueue.global(qos: .utility).async {
                let locations = HostFileSystem.availableStorageLocations()
                let ejectablePaths = Set(locations.compactMap { location -> String? in
                    guard location.kind != .cloudStorage, bridge.isEjectableVolume(location.url)
                    else { return nil }
                    return location.url.path
                })
                DispatchQueue.main.async {
                    guard !self.operationInProgress, self.presentedViewController == nil else { return }
                    let alert = UIAlertController(title: L10n.get("connections"),
                        message: discoveryError?.localizedDescription, preferredStyle: .actionSheet)
                    for location in locations {
                        alert.addAction(UIAlertAction(title: "\(L10n.get("open")): \(location.name)", style: .default) { _ in
                            self.openLocation(location.url, in: self.activePane ?? self.leftPane)
                        })
                        if ejectablePaths.contains(location.url.path) {
                            alert.addAction(UIAlertAction(title: "\(L10n.get("eject_volume")): \(location.name)", style: .default) { _ in
                                self.showProgress(L10n.get("eject_volume"), progress: 0)
                                bridge.ejectVolume(location.url) { error in
                                    self.finishProgress(error?.localizedDescription ?? L10n.get("volume_operation_complete"))
                                    self.reloadStorageLocationsBar()
                                    self.refreshAllPanes(clearSelectionIn: [])
                                }
                            })
                        }
                    }
                    for volume in unmounted {
                        guard let identifier = volume["identifier"], let name = volume["name"] else { continue }
                        alert.addAction(UIAlertAction(title: "\(L10n.get("mount_volume")): \(name)", style: .default) { _ in
                            self.showProgress(L10n.get("mount_volume"), progress: 0)
                            bridge.mountVolume(identifier) { error in
                                self.finishProgress(error?.localizedDescription ?? L10n.get("volume_operation_complete"))
                                self.reloadStorageLocationsBar()
                            }
                        })
                    }
                    alert.addAction(UIAlertAction(title: L10n.get("connect_to_server"), style: .default) { _ in self.showConnectToServerDialog() })
                    for application in bridge.installedCloudApplications() {
                        guard let name = application["name"], let path = application["path"] else { continue }
                        alert.addAction(UIAlertAction(title: "\(L10n.get("cloud_setup")): \(name)", style: .default) { _ in
                            bridge.openFile(URL(fileURLWithPath: path), application: nil) { _, error in
                                if let error { self.updateGlobalStatus(error.localizedDescription) }
                            }
                        })
                    }
                    alert.addAction(UIAlertAction(title: L10n.get("cancel"), style: .cancel))
                    alert.popoverPresentationController?.sourceView = self.view
                    alert.popoverPresentationController?.sourceRect = CGRect(x: self.view.bounds.midX, y: 100, width: 1, height: 1)
                    self.present(alert, animated: true)
                    self.updateGlobalStatus(L10n.get("connections"))
                }
            }
        }
    }

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
        let startedSecurityScope = url.startAccessingSecurityScopedResource()
        do {
            guard HostFileSystem.isDirectory(url) else { throw CocoaError(.fileReadNoSuchFile) }
            _ = try HostFileSystem.directoryContents(at: url, showHidden: false)
        } catch {
            if startedSecurityScope { url.stopAccessingSecurityScopedResource() }
            folderPickerAppliesToBothPanes = false
            showFolderAccessFailure(error)
            return
        }
        if startedSecurityScope { securityScopedURLs.append(url) }
#if !targetEnvironment(macCatalyst)
        if let data = try? url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil) {
            var saved = UserDefaults.standard.dictionary(forKey: "media_connected_folders") as? [String: Data] ?? [:]
            saved[url.path] = data; UserDefaults.standard.set(saved, forKey: "media_connected_folders")
        }
#endif
        if folderPickerAppliesToBothPanes {
            UserDefaults.standard.set(true, forKey: "ios_main_folder_onboarding_v3_completed")
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
        guard HostFileSystem.isDirectory(url) else {
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
            let startedSecurityScope = url.startAccessingSecurityScopedResource()
            do {
                guard HostFileSystem.isDirectory(url) else { throw CocoaError(.fileReadNoSuchFile) }
                _ = try HostFileSystem.directoryContents(at: url, showHidden: false)
            } catch {
                if startedSecurityScope { url.stopAccessingSecurityScopedResource() }
                throw error
            }
            if startedSecurityScope { securityScopedURLs.append(url) }
            if stale { saveFolderBookmark(url, forPane: title) }
            return url
        } catch {
            clearStoredFolderLocation(forPane: title)
            failedRestoredPaneTitles.insert(title)
            return nil
        }
#endif
    }

    private func clearStoredFolderLocation(forPane title: String) {
        UserDefaults.standard.removeObject(forKey: bookmarkKey(forPane: title))
        UserDefaults.standard.removeObject(forKey: pathKey(forPane: title))
    }

    private func showRestoredFolderAccessRecovery() {
        let failedTitles = failedRestoredPaneTitles
        failedRestoredPaneTitles.removeAll()
        if failedTitles.count == 1, let title = failedTitles.first {
            activePane = title == rightPane.title ? rightPane : leftPane
        }
        let alert = UIAlertController(
            title: L10n.get("storage_tree_failed"),
            message: L10n.get("help_access_ios"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.get("choose_another_folder"), style: .default) { _ in
            self.folderPickerAppliesToBothPanes = failedTitles.count > 1
            self.presentFolderPicker()
        })
        alert.addAction(UIAlertAction(title: L10n.get("later"), style: .cancel))
        DispatchQueue.main.async { self.present(alert, animated: true) }
    }

    private func showFolderAccessFailure(_ error: Error) {
        updateGlobalStatus(L10n.get("storage_tree_failed"))
        let alert = UIAlertController(
            title: L10n.get("storage_tree_failed"),
            message: error.localizedDescription + "\n\n" + L10n.get("help_access_ios"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.get("choose_another_folder"), style: .default) { _ in
            self.presentFolderPicker()
        })
        alert.addAction(UIAlertAction(title: L10n.get("later"), style: .cancel))
        present(alert, animated: true)
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
#if targetEnvironment(macCatalyst)
        if let browser = activePane?.onlineBrowser { fileClipboard = nil; browser.copyOnlineSelection(move: move); return }
        OneDriveBrowser.clipboard = nil
#endif
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
#if targetEnvironment(macCatalyst)
        if let remote = OneDriveBrowser.currentClipboard {
            if let browser = activePane?.onlineBrowser { browser.receiveOnline(remote.selection, move: remote.move) }
            else if let target = activePane?.currentDirectory, target.canWriteDirectory() { remote.selection.browser.exportOnline(remote.selection, to: target.url, move: remote.move) }
            return
        }
        if let browser = activePane?.onlineBrowser {
            let urls = UIPasteboard.general.urls ?? fileClipboard?.urls ?? []
            let move = fileClipboard?.move == true && fileClipboard?.urls == urls
            browser.receiveLocal(urls, move: move) { [weak self] in self?.fileClipboard = nil }
            return
        }
#endif
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
        showProgress(String(format: L10n.get(move ? "moving_items" : "copying_items"), urls.count), progress: 0, cancellable: true)
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var moved: [FileUndoRecord] = []
            var copied: [FileUndoRecord] = []
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
                    try self.operationCancellation.check()
                    if move {
                        try fm.moveItem(at: source, to: destination)
                        moved.append(FileUndoRecord(source: source, destination: destination, replacedBackup: nil))
                    } else {
                        _ = try SafeFileOperations.copyReplacing(source: source, destination: destination, replace: false,
                                                               copy: self.operationCancellation.copy)
                        copied.append(FileUndoRecord(source: source, destination: destination, replacedBackup: nil))
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
#if targetEnvironment(macCatalyst)
        if let browser = activePane?.onlineBrowser { browser.selectAllOnline(); return }
#endif
        guard let pane = activePane else { return }
        pane.selectedKeys = Set(pane.visibleEntries.filter { !$0.isUpButton }.map { $0.key() })
        pane.updateSelectionStatus()
        pane.fileList.reloadData()
    }

    @objc func refreshActivePane() {
#if targetEnvironment(macCatalyst)
        if let browser = activePane?.onlineBrowser { browser.refreshOnline(); return }
#endif
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
        updateDesktopActions()
        updateGlobalStatus(L10n.get(visible ? "hidden_visible" : "hidden_hidden"))
    }

    @objc func openSelectedEntry() {
#if targetEnvironment(macCatalyst)
        if let browser = activePane?.onlineBrowser { browser.openOnlineSelection(); return }
#endif
        guard let pane = activePane, let entry = pane.selectedEntries().first else {
            updateGlobalStatus(L10n.get("no_file_selected"))
            return
        }
        if entry.opensInPaneByDefault() {
            pane.openDirectory(entry)
        } else {
#if targetEnvironment(macCatalyst)
            openDesktopEntry(entry)
#else
            openExternal(entry)
#endif
        }
    }

#if targetEnvironment(macCatalyst)
    func openDesktopEntry(_ entry: FileEntry) {
        let mime = entry.mimeType()
        if ["image/", "video/", "audio/"].contains(where: { mime.hasPrefix($0) }) {
            previewFile(entry)
        } else {
            openExternal(entry)
        }
    }
#endif

    @objc func previewSelectedEntry() {
#if targetEnvironment(macCatalyst)
        if let browser = activePane?.onlineBrowser { browser.previewOnlineSelection(); return }
#endif
        guard let entry = activePane?.selectedEntries().first else {
            updateGlobalStatus(L10n.get("no_file_selected"))
            return
        }
        if entry.opensInPaneByDefault() {
            showFileInfo()
        } else {
#if targetEnvironment(macCatalyst)
            previewFile(entry)
#else
            openExternal(entry)
#endif
        }
    }

    @objc func duplicateSelection() {
#if targetEnvironment(macCatalyst)
        if let browser = activePane?.onlineBrowser { browser.duplicateOnlineSelection(); return }
#endif
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
            var copied: [FileUndoRecord] = []
            var failure: Error?
            for (index, source) in sources.enumerated() {
                let destination = self.uniqueURL(in: pane.currentDirectory.url, name: source.name())
                do {
                    try fm.copyItem(at: source.url, to: destination)
                    copied.append(FileUndoRecord(source: source.url, destination: destination, replacedBackup: nil))
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
#if targetEnvironment(macCatalyst)
        if let browser = activePane?.onlineBrowser { browser.infoOnlineSelection(); return }
#endif
        guard !operationInProgress, let entry = activePane?.selectedEntries().first else {
            updateGlobalStatus(L10n.get("no_file_selected"))
            return
        }
        loadFileInfo(entry, calculateFolder: false)
    }

    private func loadFileInfo(_ entry: FileEntry, calculateFolder: Bool) {
        updateGlobalStatus(L10n.get("file_info_loading"))
        let request = UUID()
        fileInfoRequest = request
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            let physical = entry.isPhysical()
            let attributes = physical ? try? fm.attributesOfItem(atPath: entry.url.path) : nil
            let values = physical ? try? entry.url.resourceValues(forKeys: [.localizedTypeDescriptionKey,
                .isDirectoryKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeIsReadOnlyKey]) : nil
            let directory = physical ? values?.isDirectory == true : entry.zipDirectory
            let bytes: Int64?
            if directory {
                bytes = calculateFolder && physical ? try? BoundedFolderSize.bytes(at: entry.url) : nil
            } else {
                bytes = physical ? (attributes?[.size] as? NSNumber)?.int64Value : entry.zipSize
            }
            let size = bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
            let formatter = DateFormatter(); formatter.dateStyle = .medium; formatter.timeStyle = .medium
            let created = (attributes?[.creationDate] as? Date).map(formatter.string) ?? "—"
            let modified = physical ? (attributes?[.modificationDate] as? Date).map(formatter.string) ?? "—" :
                (entry.zipModified > 0 ? formatter.string(from: Date(timeIntervalSince1970: Double(entry.zipModified) / 1000)) : "—")
            let permissions = (attributes?[.posixPermissions] as? NSNumber).map { String(format: "%03o", $0.intValue) } ?? "—"
            let kind = values?.localizedTypeDescription ?? L10n.get(directory ? "folder" : "file")
            var message = String(format: L10n.get("file_info_message"), entry.name(), kind,
                entry.displayPath(), size, created, modified, physical ? permissions : L10n.get("volume_read_only"))
            if physical {
                let owner = attributes?[.ownerAccountName] as? String ?? "—"
                let group = attributes?[.groupOwnerAccountName] as? String ?? "—"
                let total = values?.volumeTotalCapacity.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "—"
                let free = values?.volumeAvailableCapacity.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "—"
                message += String(format: L10n.get("file_info_extra"), owner, group, total, free)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.fileInfoRequest == request, self.presentedViewController == nil else { return }
                self.fileInfoRequest = nil
                let alert = UIAlertController(title: L10n.get("file_info"), message: message, preferredStyle: .alert)
                if directory && physical && !calculateFolder {
                    alert.addAction(UIAlertAction(title: L10n.get("calculate_folder_size"), style: .default) { _ in
                        self.loadFileInfo(entry, calculateFolder: true)
                    })
                }
                alert.addAction(UIAlertAction(title: L10n.get("ok"), style: .cancel))
                self.present(alert, animated: true)
                self.updateGlobalStatus(L10n.get("file_info"))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.fileInfoRequest == request else { return }
            self.fileInfoRequest = nil
            self.updateGlobalStatus(L10n.get("file_info_timeout"))
        }
    }

    @objc func moveSelectionToTrash() {
#if targetEnvironment(macCatalyst)
        if let browser = activePane?.onlineBrowser { browser.deleteOnlineSelection(); return }
#endif
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

    @objc func navigateBack() {
#if targetEnvironment(macCatalyst)
        if let browser = activePane?.onlineBrowser { browser.navigateOnlineBack(); return }
#endif
        activePane?.navigateBack()
    }
    @objc func copyToOtherPane() {
        transferToOtherPane(move: false)
    }
    @objc func moveToOtherPane() {
        transferToOtherPane(move: true)
    }
    private func transferToOtherPane(move: Bool) {
        guard !operationInProgress, let pane = activePane else { return }
        let other = pane === leftPane ? rightPane! : leftPane!
#if targetEnvironment(macCatalyst)
        if let source = pane.onlineBrowser {
            if let target = other.onlineBrowser { target.receiveOnline(source.selection, move: move) }
            else if other.currentDirectory.canWriteDirectory() { source.exportOnline(source.selection, to: other.currentDirectory.url, move: move) }
            return
        }
        if let target = other.onlineBrowser {
            let entries = pane.selectedEntries()
            guard entries.allSatisfy({ $0.isPhysical() }) else { updateGlobalStatus(L10n.get("zip_read_only")); return }
            target.receiveLocal(entries.map(\.url), move: move)
            return
        }
#endif
        runFileOperation(sources: pane.selectedEntries(), sourcePane: pane,
                         targetDirectory: other.currentDirectory, move: move)
    }
    @objc func navigateForward() {
#if targetEnvironment(macCatalyst)
        if let browser = activePane?.onlineBrowser { browser.navigateOnlineForward(); return }
#endif
        activePane?.navigateForward()
    }
    @objc func navigateUp() {
#if targetEnvironment(macCatalyst)
        if let browser = activePane?.onlineBrowser { browser.navigateOnlineParent(); return }
#endif
        activePane?.navigateUp()
    }

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
#if targetEnvironment(macCatalyst)
        if let browser = activePane?.onlineBrowser { browser.createOnlineFolder(); return }
#endif
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

#if !targetEnvironment(macCatalyst)
extension ViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard !results.isEmpty else { return }
        guard !mediaImportInProgress else {
            updateGlobalStatus(L10n.get("drop_busy"))
            return
        }
        do {
            let destination = try localMediaFolderURL()
            mediaImportInProgress = true
            showProgress(String(format: L10n.get("copying_items"), results.count), progress: 0)
            importPickedMedia(results, index: 0, destination: destination, imported: 0, failures: [])
        } catch {
            updateGlobalStatus(String(format: L10n.get("error_prefix"), error.localizedDescription))
        }
    }

    private func importPickedMedia(_ results: [PHPickerResult], index: Int, destination: URL,
                                   imported: Int, failures: [String]) {
        guard results.indices.contains(index) else {
            mediaImportInProgress = false
            if let pane = mediaImportPane ?? activePane {
                openLocation(destination, in: pane, persistPath: false)
            } else {
                refreshAllPanes(clearSelectionIn: [])
            }
            if failures.isEmpty {
                finishProgress(String(format: L10n.get("copied_items"), imported))
            } else {
                finishProgress(String(format: L10n.get("media_import_partial"), imported, failures.count))
            }
            return
        }

        let provider = results[index].itemProvider
        let typeIdentifier = provider.registeredTypeIdentifiers.first { identifier in
            guard let type = UTType(identifier) else { return false }
            return type.conforms(to: .image) || type.conforms(to: .movie)
        }
        guard let typeIdentifier else {
            var updatedFailures = failures
            updatedFailures.append(provider.suggestedName ?? "media")
            importPickedMedia(results, index: index + 1, destination: destination,
                              imported: imported, failures: updatedFailures)
            return
        }

        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] temporaryURL, error in
            guard let self else { return }
            var nextImported = imported
            var nextFailures = failures
            if let temporaryURL {
                do {
                    let type = UTType(typeIdentifier)
                    var name = provider.suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if name.isEmpty { name = temporaryURL.lastPathComponent }
                    if (name as NSString).pathExtension.isEmpty, let ext = type?.preferredFilenameExtension {
                        name += ".\(ext)"
                    }
                    name = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
                    if name.isEmpty { name = "media-\(UUID().uuidString)" }
                    let output = self.uniqueURL(in: destination, name: name)
                    try FileManager.default.copyItem(at: temporaryURL, to: output)
                    nextImported += 1
                } catch {
                    nextFailures.append(provider.suggestedName ?? error.localizedDescription)
                }
            } else {
                nextFailures.append(provider.suggestedName ?? error?.localizedDescription ?? "media")
            }
            let progress = Int((Double(index + 1) / Double(results.count)) * 100)
            DispatchQueue.main.async {
                self.updateProgress(progress: progress)
                self.importPickedMedia(results, index: index + 1, destination: destination,
                                       imported: nextImported, failures: nextFailures)
            }
        }
    }
}

extension ViewController: MPMediaPickerControllerDelegate {
    func mediaPickerDidCancel(_ mediaPicker: MPMediaPickerController) {
        mediaPicker.dismiss(animated: true)
    }

    func mediaPicker(_ mediaPicker: MPMediaPickerController, didPickMediaItems mediaItemCollection: MPMediaItemCollection) {
        mediaPicker.dismiss(animated: true)
        guard !mediaItemCollection.items.isEmpty else { return }
        let player = MPMusicPlayerController.applicationMusicPlayer
        player.setQueue(with: mediaItemCollection)
        player.prepareToPlay { [weak self] error in
            DispatchQueue.main.async {
                if let error {
                    self?.updateGlobalStatus(String(format: L10n.get("error_prefix"), error.localizedDescription))
                } else {
                    player.play()
                    self?.updateGlobalStatus(String(format: L10n.get("music_playing"), mediaItemCollection.items.count))
                }
            }
        }
    }
}
#endif
