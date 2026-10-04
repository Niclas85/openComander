#if !targetEnvironment(macCatalyst)
import UIKit
import Photos
import AVKit
import MediaPlayer
import UniformTypeIdentifiers

enum MediaExportFiles {
    static func cleanInterruptedExports() {
        let manager = FileManager.default
        let children = (try? manager.contentsOfDirectory(at: manager.temporaryDirectory, includingPropertiesForKeys: nil)) ?? []
        for url in children where url.lastPathComponent.hasPrefix("OpenCommander-export-") || url.lastPathComponent.hasPrefix("OpenCommander-music-") {
            try? manager.removeItem(at: url)
        }
    }
}

// A source hub: each row grants access through the API that owns that content.
final class StorageSourcesController: UITableViewController {
    struct Location { let title: String; let open: () -> Void; var forget: (() -> Void)? = nil }
    var locations: [Location] = []
    var chooseFolder: (() -> Void)?
    var localFiles: (() -> Void)?
    var importedFiles: (() -> Void)?
    var importMedia: (() -> Void)?
    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.get("media_locations")
        view.accessibilityIdentifier = "StorageSources"
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "StorageSourcesClose"
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 64
    }
    @objc private func close() { dismiss(animated: true) }
    override func numberOfSections(in tableView: UITableView) -> Int { 2 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 3 : 4 + locations.count
    }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        L10n.get(section == 0 ? "media_libraries" : "media_files")
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 0 ? L10n.get("media_source_note") : L10n.get("help_access_ios")
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let keys = indexPath.section == 0 ? ["media_photos", "media_videos", "media_music"] :
            ["choose_another_folder", "local_documents", "media_folder", "import_photos_videos"]
        cell.textLabel?.text = indexPath.row < keys.count ? L10n.get(keys[indexPath.row]) : locations[indexPath.row - 4].title
        cell.textLabel?.numberOfLines = 0
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityIdentifier = indexPath.row < keys.count ? "Source-\(keys[indexPath.row])" : "Source-saved-\(indexPath.row - 4)"
        let icons = indexPath.section == 0 ? ["photo", "video", "music.note"] : ["folder.badge.plus", "doc", "tray", "square.and.arrow.down"]
        cell.imageView?.image = UIImage(systemName: indexPath.row < icons.count ? icons[indexPath.row] : "folder")
        return cell
    }
    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        indexPath.section == 1 && indexPath.row >= 4 && locations[indexPath.row - 4].forget != nil
    }
    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard self.tableView(tableView, canEditRowAt: indexPath) else { return nil }
        let action = UIContextualAction(style: .normal, title: L10n.get("media_disconnect")) { [weak self] _, _, completed in
            self?.tableView(tableView, commit: .delete, forRowAt: indexPath); completed(true)
        }
        return UISwipeActionsConfiguration(actions: [action])
    }
    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        locations[indexPath.row - 4].forget?()
        locations.remove(at: indexPath.row - 4)
        tableView.deleteRows(at: [indexPath], with: .automatic)
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0 {
            let controller: UIViewController = indexPath.row == 2 ? MusicLibraryController() : PhotoLibraryController(videos: indexPath.row == 1)
            navigationController?.pushViewController(controller, animated: true)
        } else {
            let action = indexPath.row < 4 ? [chooseFolder, localFiles, importedFiles, importMedia][indexPath.row] : locations[indexPath.row - 4].open
            dismiss(animated: true) { action?() }
        }
    }
}

private func showMediaError(_ controller: UIViewController, _ message: String) {
    let alert = UIAlertController(title: L10n.get("media_load_failed"), message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: L10n.get("ok"), style: .default))
    controller.present(alert, animated: true)
}

// Streaming export keeps large videos out of RAM and supports cancellation.
private final class MediaExportWriter {
    private let lock = NSLock()
    private var handle: FileHandle?
    private var failure: Error?
    var error: Error? { lock.lock(); defer { lock.unlock() }; return failure }
    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        handle = try FileHandle(forWritingTo: url)
    }
    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard failure == nil, let handle else { return }
        do { try handle.write(contentsOf: data) } catch { failure = error }
    }
    func finish() {
        lock.lock(); defer { lock.unlock() }
        do { try handle?.close() } catch { if failure == nil { failure = error } }
        handle = nil
    }
    deinit { finish() }
}

private final class PhotoCell: UICollectionViewCell {
    let image = UIImageView()
    let badge = UILabel()
    var request: PHImageRequestID = PHInvalidImageRequestID
    var assetID: String?
    override init(frame: CGRect) {
        super.init(frame: frame)
        image.contentMode = .scaleAspectFill; image.clipsToBounds = true
        image.translatesAutoresizingMaskIntoConstraints = false
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.textColor = .white; badge.backgroundColor = .black.withAlphaComponent(0.6)
        contentView.addSubview(image); contentView.addSubview(badge)
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: contentView.leadingAnchor), image.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            image.topAnchor.constraint(equalTo: contentView.topAnchor), image.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            badge.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4), badge.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isSelected: Bool { didSet { contentView.layer.borderWidth = isSelected ? 4 : 0; contentView.layer.borderColor = UIColor.systemBlue.cgColor } }
    override func prepareForReuse() {
        super.prepareForReuse()
        if request != PHInvalidImageRequestID { PHImageManager.default().cancelImageRequest(request) }
        image.image = nil; assetID = nil; request = PHInvalidImageRequestID
    }
}

final class PhotoLibraryController: UICollectionViewController, PHPhotoLibraryChangeObserver, UIDocumentPickerDelegate {
    private let videos: Bool
    private let album: PHAssetCollection?
    private var assets: PHFetchResult<PHAsset> = PHAsset.fetchAssets(withLocalIdentifiers: [], options: nil)
    private var selecting = false
    private var exporting = false
    private var exportDirectory: URL?
    private var exportRequest: PHAssetResourceDataRequestID?
    private var exportWriter: MediaExportWriter?
    private var exportGeneration = 0
    private let info = UILabel()
    private let indicator = UIActivityIndicatorView(style: .large)
    init(videos: Bool, album: PHAssetCollection? = nil) {
        self.videos = videos; self.album = album
        let layout = UICollectionViewFlowLayout(); layout.minimumInteritemSpacing = 3; layout.minimumLineSpacing = 3
        super.init(collectionViewLayout: layout)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = album?.localizedTitle ?? L10n.get(videos ? "media_videos" : "media_photos")
        view.accessibilityIdentifier = "PhotoLibrary"
        collectionView.backgroundColor = .systemBackground
        collectionView.register(PhotoCell.self, forCellWithReuseIdentifier: "photo")
        collectionView.allowsMultipleSelection = true
        info.textAlignment = .center; info.numberOfLines = 0; info.font = .preferredFont(forTextStyle: .body)
        info.accessibilityIdentifier = "PhotoLibraryMessage"
        collectionView.backgroundView = info
        indicator.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(indicator)
        NSLayoutConstraint.activate([indicator.centerXAnchor.constraint(equalTo: view.centerXAnchor), indicator.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
        PHPhotoLibrary.shared().register(self)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: UIApplication.didBecomeActiveNotification, object: nil)
        refresh()
    }
    deinit {
        if let exportRequest { PHAssetResourceManager.default().cancelDataRequest(exportRequest) }
        exportWriter?.finish()
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
        NotificationCenter.default.removeObserver(self)
        if let exportDirectory { try? FileManager.default.removeItem(at: exportDirectory) }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let columns = max(3, floor(collectionView.bounds.width / 120))
        let width = floor((collectionView.bounds.width - (columns - 1) * 3) / columns)
        (collectionViewLayout as? UICollectionViewFlowLayout)?.itemSize = CGSize(width: width, height: width)
    }
    @objc private func refresh() {
        guard !exporting else { return }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            info.text = L10n.get("media_permission")
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
            return
        }
        guard status == .authorized || status == .limited else {
            assets = PHAsset.fetchAssets(withLocalIdentifiers: [], options: nil)
            info.text = L10n.get("media_permission")
            navigationItem.rightBarButtonItems = [UIBarButtonItem(title: L10n.get("open_settings"), style: .plain, target: self, action: #selector(settings))]
            collectionView.reloadData(); return
        }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", videos ? PHAssetMediaType.video.rawValue : PHAssetMediaType.image.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        assets = album.map { PHAsset.fetchAssets(in: $0, options: options) } ?? PHAsset.fetchAssets(with: options)
        info.text = assets.count == 0 ? L10n.get("media_empty") : nil
        collectionView.reloadData()
        updateActions()
    }
    func photoLibraryDidChange(_ changeInstance: PHChange) { DispatchQueue.main.async { [weak self] in self?.refresh() } }
    private func updateActions() {
        if exporting {
            navigationItem.rightBarButtonItems = [UIBarButtonItem(title: L10n.get("cancel"), style: .plain, target: self, action: #selector(cancelExport))]
            return
        }
        let select = UIBarButtonItem(title: L10n.get(selecting ? "cancel" : "media_select"), style: .plain, target: self, action: #selector(toggleSelection))
        select.accessibilityIdentifier = "PhotoSelect"
        let export = UIBarButtonItem(title: L10n.get("media_export"), style: .plain, target: self, action: #selector(exportSelection))
        export.accessibilityIdentifier = "PhotoExport"
        export.isEnabled = selecting && !(collectionView.indexPathsForSelectedItems ?? []).isEmpty && !exporting
        var actions = selecting ? [export, select] : [select]
        if !selecting {
            if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited {
                actions.append(UIBarButtonItem(title: L10n.get("media_access"), style: .plain, target: self, action: #selector(access)))
            } else if album == nil {
                actions.append(UIBarButtonItem(title: L10n.get("media_albums"), style: .plain, target: self, action: #selector(albums)))
            }
        }
        navigationItem.rightBarButtonItems = actions
    }
    @objc private func settings() { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
    @objc private func access() { PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: self) }
    @objc private func toggleSelection() {
        selecting.toggle()
        for path in collectionView.indexPathsForSelectedItems ?? [] { collectionView.deselectItem(at: path, animated: false) }
        updateActions()
    }
    @objc private func albums() {
        navigationController?.pushViewController(PhotoAlbumsController(videos: videos), animated: true)
    }
    override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { assets.count }
    override func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "photo", for: indexPath) as! PhotoCell
        let asset = assets.object(at: indexPath.item); cell.assetID = asset.localIdentifier
        cell.accessibilityIdentifier = "PhotoAsset-\(indexPath.item)"
        cell.isAccessibilityElement = true
        cell.accessibilityLabel = asset.creationDate.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? title
        cell.badge.text = videos ? String(format: "%d:%02d", Int(asset.duration) / 60, Int(asset.duration) % 60) : nil
        let options = PHImageRequestOptions(); options.isNetworkAccessAllowed = true
        cell.request = PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 300, height: 300), contentMode: .aspectFill, options: options) { [weak cell] image, _ in
            DispatchQueue.main.async {
                guard cell?.assetID == asset.localIdentifier else { return }
                cell?.image.image = image
            }
        }
        return cell
    }
    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if selecting { updateActions(); return }
        collectionView.deselectItem(at: indexPath, animated: false)
        let viewer = LibraryMediaViewer(assets: assets, index: indexPath.item)
        viewer.modalPresentationStyle = .fullScreen
        present(viewer, animated: true)
    }
    override func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) { updateActions() }
    @objc private func exportSelection() {
        guard !exporting else { return }
        let selection = (collectionView.indexPathsForSelectedItems ?? []).sorted().map { assets.object(at: $0.item) }
        guard !selection.isEmpty else { return }
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OpenCommander-export-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            exportDirectory = directory; exportGeneration += 1; exporting = true; indicator.startAnimating(); updateActions()
            navigationItem.hidesBackButton = true; navigationController?.isModalInPresentation = true
            exportNext(selection, index: 0, directory: directory, outputs: [])
        } catch { showMediaError(self, error.localizedDescription) }
    }
    private func exportNext(_ selection: [PHAsset], index: Int, directory: URL, outputs: [URL]) {
        guard index < selection.count else {
            exporting = false; indicator.stopAnimating(); navigationItem.hidesBackButton = false
            navigationController?.isModalInPresentation = false; updateActions()
            let picker = UIDocumentPickerViewController(forExporting: outputs, asCopy: true)
            picker.delegate = self; present(picker, animated: true); return
        }
        let asset = selection[index]
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == (asset.mediaType == .video ? .video : .photo) }) ?? resources.first else {
            exportFailed(L10n.get("media_load_failed")); return
        }
        let name = URL(fileURLWithPath: resource.originalFilename).lastPathComponent
        var output = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: output.path) { output = directory.appendingPathComponent("\(index)-\(name)") }
        let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = true
        do {
            let writer = try MediaExportWriter(url: output); exportWriter = writer
            let token = exportGeneration
            exportRequest = PHAssetResourceManager.default().requestData(for: resource, options: options, dataReceivedHandler: { data in
                writer.append(data)
            }, completionHandler: { [weak self] error in
                writer.finish()
                DispatchQueue.main.async {
                    guard let self, self.exportGeneration == token else { return }
                    self.exportRequest = nil; self.exportWriter = nil
                    if let error = error ?? writer.error { self.exportFailed(error.localizedDescription) }
                    else { self.exportNext(selection, index: index + 1, directory: directory, outputs: outputs + [output]) }
                }
            })
        } catch { exportFailed(error.localizedDescription) }
    }
    @objc private func cancelExport() {
        exportGeneration += 1
        if let exportRequest { PHAssetResourceManager.default().cancelDataRequest(exportRequest) }
        exportRequest = nil; exportWriter?.finish(); exportWriter = nil
        cleanupExport(); exporting = false; indicator.stopAnimating(); navigationItem.hidesBackButton = false
        navigationController?.isModalInPresentation = false; updateActions()
    }
    private func exportFailed(_ message: String) {
        cleanupExport(); exporting = false; indicator.stopAnimating(); navigationItem.hidesBackButton = false
        navigationController?.isModalInPresentation = false; updateActions(); showMediaError(self, message)
    }
    private func cleanupExport() { if let exportDirectory { try? FileManager.default.removeItem(at: exportDirectory) }; exportDirectory = nil }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { cleanupExport() }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { cleanupExport(); if selecting { toggleSelection() } }
}

private final class PhotoAlbumsController: UITableViewController {
    private let videos: Bool
    private var albums: [PHAssetCollection] = []
    init(videos: Bool) { self.videos = videos; super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad(); title = L10n.get("media_albums")
        NotificationCenter.default.addObserver(self, selector: #selector(refreshAlbums), name: UIApplication.didBecomeActiveNotification, object: nil)
        refreshAlbums()
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); refreshAlbums() }
    @objc private func refreshAlbums() {
        albums = []
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { tableView.reloadData(); return }
        for type in [PHAssetCollectionType.smartAlbum, .album] {
            PHAssetCollection.fetchAssetCollections(with: type, subtype: .any, options: nil).enumerateObjects { collection, _, _ in self.albums.append(collection) }
        }
        tableView.reloadData()
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { albums.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil); cell.textLabel?.text = albums[indexPath.row].localizedTitle
        cell.accessoryType = .disclosureIndicator; return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        navigationController?.pushViewController(PhotoLibraryController(videos: videos, album: albums[indexPath.row]), animated: true)
    }
}

private final class LibraryMediaViewer: UIViewController, UIScrollViewDelegate {
    private let assets: PHFetchResult<PHAsset>
    private var index: Int
    private var request = PHInvalidImageRequestID
    private var generation = 0
    private let image = UIImageView()
    private let scroll = UIScrollView()
    private let counter = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let retry = UIButton(type: .system)
    private var video: AVPlayerViewController?
    private var videoObserver: Any?
    init(assets: PHFetchResult<PHAsset>, index: Int) { self.assets = assets; self.index = index; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    deinit {
        if request != PHInvalidImageRequestID { PHImageManager.default().cancelImageRequest(request) }
        if let videoObserver { video?.player?.removeTimeObserver(videoObserver) }
    }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black; view.accessibilityIdentifier = "LibraryMediaViewer"
        scroll.delegate = self; scroll.minimumZoomScale = 1; scroll.maximumZoomScale = 5
        image.contentMode = .scaleAspectFit; image.accessibilityIdentifier = "LibraryMediaImage"; image.isAccessibilityElement = true
        scroll.addSubview(image); view.addSubview(scroll)
        let close = UIButton(type: .system); close.setTitle("×", for: .normal); close.titleLabel?.font = .systemFont(ofSize: 32)
        close.accessibilityIdentifier = "LibraryMediaClose"; close.accessibilityLabel = L10n.get("cancel"); close.addTarget(self, action: #selector(closeViewer), for: .touchUpInside)
        let previous = UIButton(type: .system); previous.setImage(UIImage(systemName: "chevron.left"), for: .normal)
        previous.accessibilityIdentifier = "LibraryMediaPrevious"; previous.accessibilityLabel = L10n.get("media_previous"); previous.addTarget(self, action: #selector(previousAsset), for: .touchUpInside)
        let next = UIButton(type: .system); next.setImage(UIImage(systemName: "chevron.right"), for: .normal)
        next.accessibilityIdentifier = "LibraryMediaNext"; next.accessibilityLabel = L10n.get("media_next"); next.addTarget(self, action: #selector(nextAsset), for: .touchUpInside)
        counter.textColor = .white; counter.textAlignment = .center; counter.accessibilityIdentifier = "LibraryMediaCounter"
        let header = UIStackView(arrangedSubviews: [close, previous, counter, next]); header.spacing = 12
        header.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(header)
        for button in [close, previous, next] { button.widthAnchor.constraint(equalToConstant: 44).isActive = true; button.tintColor = .white }
        NSLayoutConstraint.activate([header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), header.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8), header.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8), header.heightAnchor.constraint(equalToConstant: 48)])
        spinner.color = .white; spinner.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(spinner)
        retry.setTitle(L10n.get("directory_retry"), for: .normal); retry.addTarget(self, action: #selector(load), for: .touchUpInside)
        retry.translatesAutoresizingMaskIntoConstraints = false; retry.accessibilityIdentifier = "LibraryMediaRetry"; view.addSubview(retry)
        NSLayoutConstraint.activate([spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor), spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor), retry.centerXAnchor.constraint(equalTo: view.centerXAnchor), retry.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: 55)])
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swipe(_:))); swipe.direction = direction; view.addGestureRecognizer(swipe)
        }
        load()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let top = view.safeAreaInsets.top + 48
        scroll.frame = CGRect(x: 0, y: top, width: view.bounds.width, height: max(0, view.bounds.height - top - view.safeAreaInsets.bottom))
        if scroll.zoomScale == 1 { image.frame = scroll.bounds; scroll.contentSize = scroll.bounds.size }
        video?.view.frame = scroll.frame
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { image }
    @objc private func closeViewer() { video?.player?.pause(); dismiss(animated: true) }
    @objc private func previousAsset() { if index > 0 { index -= 1; load() } }
    @objc private func nextAsset() { if index + 1 < assets.count { index += 1; load() } }
    @objc private func swipe(_ recognizer: UISwipeGestureRecognizer) { guard scroll.zoomScale == 1 else { return }; recognizer.direction == .left ? nextAsset() : previousAsset() }
    @objc private func load() {
        generation += 1; let token = generation
        if request != PHInvalidImageRequestID { PHImageManager.default().cancelImageRequest(request) }
        if let videoObserver { video?.player?.removeTimeObserver(videoObserver); self.videoObserver = nil }
        video?.player?.pause(); video?.willMove(toParent: nil); video?.view.removeFromSuperview(); video?.removeFromParent(); video = nil
        scroll.setZoomScale(1, animated: false); image.image = nil; image.accessibilityValue = "loading"; retry.isHidden = true; spinner.startAnimating()
        let asset = assets.object(at: index)
        counter.accessibilityValue = nil
        counter.text = "\(index + 1) / \(assets.count)"
        image.accessibilityLabel = counter.text
        if asset.mediaType == .video {
            let options = PHVideoRequestOptions(); options.isNetworkAccessAllowed = true
            request = PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { [weak self] item, info in
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    self.spinner.stopAnimating()
                    guard let item else { self.retry.isHidden = false; self.counter.text = L10n.get("media_load_failed"); return }
                    let player = AVPlayerViewController(); player.player = AVPlayer(playerItem: item)
                    player.view.accessibilityIdentifier = "LibraryVideoPlayer"
                    self.addChild(player); self.view.insertSubview(player.view, aboveSubview: self.scroll); player.view.frame = self.scroll.frame; player.didMove(toParent: self); self.video = player
                    self.counter.accessibilityValue = "0.0"
                    self.videoObserver = player.player?.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
                        guard let self, self.generation == token else { return }
                        let seconds = time.seconds.isFinite ? max(0, time.seconds) : 0
                        self.counter.accessibilityValue = String(format: "%.1f", seconds)
                    }
                }
            }
        } else {
            let options = PHImageRequestOptions(); options.isNetworkAccessAllowed = true; options.deliveryMode = .highQualityFormat
            let size = CGSize(width: max(view.bounds.width, 1) * UIScreen.main.scale, height: max(view.bounds.height, 1) * UIScreen.main.scale)
            request = PHImageManager.default().requestImage(for: asset, targetSize: size, contentMode: .aspectFit, options: options) { [weak self] result, info in
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    self.spinner.stopAnimating(); self.image.image = result; self.image.accessibilityValue = result == nil ? "failed" : "loaded"
                    self.retry.isHidden = result != nil
                    if result == nil { self.counter.text = L10n.get("media_load_failed") }
                }
            }
        }
    }
}

final class MusicLibraryController: UITableViewController, UISearchResultsUpdating, UIDocumentPickerDelegate {
    private let initialSongs: [MPMediaItem]?
    private let grouping = UISegmentedControl(items: [L10n.get("media_music"), L10n.get("media_albums"), L10n.get("media_artists")])
    private var groupNames: [String] = []
    init(items: [MPMediaItem]? = nil) { initialSongs = items; super.init(style: .plain) }
    required init?(coder: NSCoder) { fatalError() }
    private var songs: [MPMediaItem] = []
    private var shown: [MPMediaItem] = []
    private let player = MPMusicPlayerController.applicationMusicPlayer
    private let search = UISearchController(searchResultsController: nil)
    private let message = UILabel()
    private let nowPlaying = UILabel()
    private var timer: Timer?
    private var exportSession: AVAssetExportSession?
    private var exportDirectory: URL?
    private var busy = false
    private var exportGeneration = 0
    override func viewDidLoad() {
        super.viewDidLoad(); if title == nil { title = L10n.get("media_music") }; view.accessibilityIdentifier = "MusicLibrary"
        search.searchResultsUpdater = self; search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = L10n.get("media_music_search"); navigationItem.searchController = search
        grouping.selectedSegmentIndex = 0; grouping.addTarget(self, action: #selector(groupChanged), for: .valueChanged)
        if initialSongs == nil { navigationItem.titleView = grouping }
        message.numberOfLines = 0; message.textAlignment = .center; message.accessibilityIdentifier = "MusicLibraryMessage"; tableView.backgroundView = message
        nowPlaying.numberOfLines = 2; nowPlaying.textAlignment = .center; nowPlaying.font = .preferredFont(forTextStyle: .caption1)
        nowPlaying.accessibilityIdentifier = "MusicNowPlaying"
        nowPlaying.isUserInteractionEnabled = true
        nowPlaying.accessibilityHint = L10n.get("media_export")
        let previous = UIBarButtonItem(image: UIImage(systemName: "backward.end.fill"), style: .plain, target: self, action: #selector(previousSong))
        let play = UIBarButtonItem(image: UIImage(systemName: "playpause.fill"), style: .plain, target: self, action: #selector(togglePlayback)); play.accessibilityIdentifier = "MusicPlayPause"
        let stop = UIBarButtonItem(image: UIImage(systemName: "stop.fill"), style: .plain, target: self, action: #selector(stopPlayback)); stop.accessibilityIdentifier = "MusicStop"
        let next = UIBarButtonItem(image: UIImage(systemName: "forward.end.fill"), style: .plain, target: self, action: #selector(nextSong))
        previous.accessibilityLabel = L10n.get("media_previous"); play.accessibilityLabel = L10n.get("media_play_pause"); stop.accessibilityLabel = L10n.get("media_stop"); next.accessibilityLabel = L10n.get("media_next")
        toolbarItems = [previous, .flexibleSpace(), play, .flexibleSpace(), stop, .flexibleSpace(), next]
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: L10n.get("media_export"), style: .plain, target: self, action: #selector(exportSong))
        player.beginGeneratingPlaybackNotifications()
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: .MPMediaLibraryDidChange, object: nil)
        MPMediaLibrary.default().beginGeneratingLibraryChangeNotifications()
        refresh()
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated); navigationController?.setToolbarHidden(false, animated: animated)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updatePlayer() }
        updatePlayer()
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated); timer?.invalidate(); timer = nil
        navigationController?.setToolbarHidden(true, animated: animated)
        // The app has no background audio mode: stop when leaving this player.
        player.stop()
    }
    deinit {
        timer?.invalidate(); NotificationCenter.default.removeObserver(self)
        player.endGeneratingPlaybackNotifications(); MPMediaLibrary.default().endGeneratingLibraryChangeNotifications()
        exportSession?.cancelExport(); cleanupExport()
    }
    @objc private func refresh() {
        let status = MPMediaLibrary.authorizationStatus()
        if status == .notDetermined {
            MPMediaLibrary.requestAuthorization { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }; return
        }
        guard status == .authorized else {
            songs = []; shown = []; message.text = L10n.get("media_permission"); player.stop()
            navigationItem.rightBarButtonItem = UIBarButtonItem(title: L10n.get("open_settings"), style: .plain, target: self, action: #selector(settings))
            tableView.reloadData(); updatePlayer(); return
        }
        songs = (initialSongs ?? MPMediaQuery.songs().items ?? []).sorted { ($0.title ?? "").localizedStandardCompare($1.title ?? "") == .orderedAscending }
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: L10n.get("media_export"), style: .plain, target: self, action: #selector(exportSong))
        updateSearchResults(for: search); updatePlayer()
    }
    @objc private func settings() { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
    func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text ?? ""
        shown = text.isEmpty ? songs : songs.filter { [$0.title, $0.artist, $0.albumTitle].compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(text) } }
        if MPMediaLibrary.authorizationStatus() == .authorized { message.text = shown.isEmpty ? L10n.get("media_empty") : nil }
        let groups = shown.map { grouping.selectedSegmentIndex == 1 ? ($0.albumTitle ?? "—") : ($0.artist ?? "—") }
        groupNames = Array(Set(groups)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        tableView.reloadData()
    }
    @objc private func groupChanged() { updateSearchResults(for: search) }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { grouping.selectedSegmentIndex == 0 ? shown.count : groupNames.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if grouping.selectedSegmentIndex != 0 {
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil); cell.textLabel?.text = groupNames[indexPath.row]
            cell.accessoryType = .disclosureIndicator; cell.accessibilityIdentifier = "MusicGroup-\(indexPath.row)"; return cell
        }
        let song = shown[indexPath.row]; let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = song.title; cell.detailTextLabel?.text = [song.artist, song.albumTitle].compactMap { $0 }.joined(separator: " · ")
        cell.textLabel?.numberOfLines = 0; cell.detailTextLabel?.numberOfLines = 0
        cell.imageView?.image = song.artwork?.image(at: CGSize(width: 44, height: 44)) ?? UIImage(systemName: "music.note")
        cell.accessibilityIdentifier = "MusicSong-\(indexPath.row)"; return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true); guard !busy else { return }
        if grouping.selectedSegmentIndex != 0 {
            let name = groupNames[indexPath.row]
            let items = shown.filter { (grouping.selectedSegmentIndex == 1 ? ($0.albumTitle ?? "—") : ($0.artist ?? "—")) == name }
            let child = MusicLibraryController(items: items); child.title = name
            navigationController?.pushViewController(child, animated: true); return
        }
        let song = shown[indexPath.row]; player.setQueue(with: MPMediaItemCollection(items: shown)); player.nowPlayingItem = song
        busy = true
        player.prepareToPlay { [weak self] error in DispatchQueue.main.async {
            guard let self else { return }; self.busy = false
            if let error { showMediaError(self, error.localizedDescription) }
            else if self.view.window != nil { self.player.play(); self.updatePlayer() }
        } }
    }
    @objc private func togglePlayback() { guard !busy else { return }; player.playbackState == .playing ? player.pause() : player.play(); updatePlayer() }
    @objc private func stopPlayback() { player.stop(); updatePlayer() }
    @objc private func previousSong() { player.skipToPreviousItem(); updatePlayer() }
    @objc private func nextSong() { player.skipToNextItem(); updatePlayer() }
    private func updatePlayer() {
        if exportSession != nil {
            navigationItem.rightBarButtonItem = UIBarButtonItem(title: L10n.get("cancel"), style: .plain, target: self, action: #selector(cancelMusicExport))
        }
        navigationItem.rightBarButtonItem?.isEnabled = exportSession != nil || (!busy && (MPMediaLibrary.authorizationStatus() != .authorized || player.nowPlayingItem != nil))
        for item in toolbarItems ?? [] where item.action != nil {
            item.isEnabled = !busy && MPMediaLibrary.authorizationStatus() == .authorized && player.nowPlayingItem != nil
        }
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "MusicExport"
        guard let song = player.nowPlayingItem else { tableView.tableHeaderView = nil; return }
        let time = max(0, Int(player.currentPlaybackTime.isFinite ? player.currentPlaybackTime : 0))
        nowPlaying.text = "\(player.playbackState == .playing ? "▶" : "Ⅱ") \(song.title ?? "")\n\(time / 60):\(String(format: "%02d", time % 60)) / \(Int(song.playbackDuration) / 60):\(String(format: "%02d", Int(song.playbackDuration) % 60))"
        nowPlaying.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 70); tableView.tableHeaderView = nowPlaying
    }
    @objc private func exportSong() {
        guard !busy, let song = player.nowPlayingItem else { return }
        guard !song.hasProtectedAsset, let url = song.assetURL else { showMediaError(self, L10n.get("media_music_protected")); return }
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { showMediaError(self, L10n.get("media_music_protected")); return }
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OpenCommander-music-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); exportDirectory = directory
            let output = directory.appendingPathComponent("\((song.title ?? "music").replacingOccurrences(of: "/", with: "-")).m4a")
            session.outputURL = output; session.outputFileType = .m4a; exportSession = session; busy = true; exportGeneration += 1
            let token = exportGeneration; updatePlayer()
            navigationItem.hidesBackButton = true; navigationController?.isModalInPresentation = true
            session.exportAsynchronously { [weak self] in DispatchQueue.main.async {
                guard let self else { try? FileManager.default.removeItem(at: directory); return }
                guard self.exportGeneration == token else { try? FileManager.default.removeItem(at: directory); return }
                self.busy = false; self.exportSession = nil
                self.navigationItem.rightBarButtonItem = UIBarButtonItem(title: L10n.get("media_export"), style: .plain, target: self, action: #selector(self.exportSong))
                self.navigationItem.hidesBackButton = false; self.navigationController?.isModalInPresentation = false; self.updatePlayer()
                if session.status == .completed {
                    let picker = UIDocumentPickerViewController(forExporting: [output], asCopy: true); picker.delegate = self; self.present(picker, animated: true)
                } else { self.cleanupExport(); showMediaError(self, session.error?.localizedDescription ?? L10n.get("media_load_failed")) }
            } }
        } catch { cleanupExport(); showMediaError(self, error.localizedDescription) }
    }
    @objc private func cancelMusicExport() {
        exportGeneration += 1; exportSession?.cancelExport(); exportSession = nil
        exportDirectory = nil; busy = false; navigationItem.hidesBackButton = false
        navigationController?.isModalInPresentation = false
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: L10n.get("media_export"), style: .plain, target: self, action: #selector(exportSong))
        updatePlayer()
    }
    private func cleanupExport() { if let exportDirectory { try? FileManager.default.removeItem(at: exportDirectory) }; exportDirectory = nil }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { cleanupExport() }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { cleanupExport() }
}
#endif
