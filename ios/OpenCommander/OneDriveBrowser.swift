#if targetEnvironment(macCatalyst)
import UIKit
import UniformTypeIdentifiers

/// A separate online browser: remote entries are never mistaken for local FileEntry paths.
@MainActor final class OneDriveBrowser: UITableViewController, UIDocumentPickerDelegate {
    private var client: OneDriveClient?
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
    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "OneDrive online"
        isModalInPresentation = true
        tableView.accessibilityIdentifier = "OneDriveOnlineFiles"
        message.numberOfLines = 0; message.textAlignment = .center
        message.textColor = .secondaryLabel
        message.accessibilityIdentifier = "OneDriveOnlineStatus"
        tableView.backgroundView = message
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: text("Schließen", "Close"), style: .done, target: self, action: #selector(close))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: text("Aktionen", "Actions"), style: .plain, target: self, action: #selector(actions))
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(reload), for: .valueChanged)
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
    @objc private func close() { work?.cancel(); dismiss(animated: true) }
    private func run(_ action: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        work = Task { [weak self] in
            guard let self else { return }
            defer { self.busy = false; self.refreshControl?.endRefreshing() }
            do { try await action() }
            catch is CancellationError { }
            catch { self.error(error.localizedDescription) }
        }
    }
    private func error(_ description: String) {
        message.text = items.isEmpty ? description : nil
        guard presentedViewController == nil, view.window != nil else { return }
        let alert = UIAlertController(title: "OneDrive", message: description, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
    private func load() async throws {
        guard let client else { return }
        let listing = try await client.children(of: folders.last?.id)
        try Task.checkCancellation()
        items = listing
        authenticated = true
        title = folders.last?.name ?? "OneDrive online"
        message.text = items.isEmpty ? text("Dieser Ordner ist leer.", "This folder is empty.") : nil
        tableView.reloadData()
    }
    @objc private func reload() {
        guard client != nil else { refreshControl?.endRefreshing(); return }
        run { [weak self] in try await self?.load() }
    }
    @objc private func actions() {
        guard !busy else { return }
        let menu = UIAlertController(title: "OneDrive online", message: text("Online-Dateien direkt in OpenCommander. Uploads: einzelne Dateien bis 20 MB.", "Online files directly in OpenCommander. Upload: individual files up to 20 MB."), preferredStyle: .actionSheet)
        menu.addAction(UIAlertAction(title: text("Mit Microsoft verbinden", "Connect to Microsoft"), style: .default) { [weak self] _ in self?.connect() })
        menu.addAction(UIAlertAction(title: text("Microsoft-App einrichten", "Configure Microsoft app"), style: .default) { [weak self] _ in self?.configure() })
        if client != nil && authenticated {
            if !folders.isEmpty { menu.addAction(UIAlertAction(title: text("Übergeordneter Ordner", "Parent folder"), style: .default) { [weak self] _ in
                self?.folders.removeLast(); self?.items = []; self?.tableView.reloadData(); self?.reload()
            }) }
            menu.addAction(UIAlertAction(title: text("Aktualisieren", "Refresh"), style: .default) { [weak self] _ in self?.reload() })
            menu.addAction(UIAlertAction(title: text("Neuer Ordner", "New folder"), style: .default) { [weak self] _ in self?.namePrompt(item: nil) })
            menu.addAction(UIAlertAction(title: text("Datei hochladen…", "Upload file…"), style: .default) { [weak self] _ in
                guard let self else { return }
                let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: false)
                picker.delegate = self; picker.allowsMultipleSelection = false
                self.present(picker, animated: true)
            })
            menu.addAction(UIAlertAction(title: text("Verbindung trennen", "Disconnect"), style: .destructive) { [weak self] _ in self?.disconnect() })
        }
        menu.addAction(UIAlertAction(title: text("Abbrechen", "Cancel"), style: .cancel))
        menu.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
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
            self.authenticated = false; self.items = []; self.folders = []; self.tableView.reloadData()
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
                try self.client?.disconnect(); self.authenticated = false; self.items = []; self.folders = []; self.tableView.reloadData()
                self.message.text = self.text("Verbindung getrennt.", "Disconnected.")
            } catch { self.error(error.localizedDescription) }
        })
        alert.addAction(UIAlertAction(title: text("Abbrechen", "Cancel"), style: .cancel))
        present(alert, animated: true)
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { items.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = items[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = item.name
        cell.detailTextLabel?.text = item.isFolder ? text("Ordner", "Folder") : ByteCountFormatter.string(fromByteCount: item.size ?? 0, countStyle: .file)
        cell.imageView?.image = UIImage(systemName: item.isFolder ? "folder.fill" : "doc")
        cell.accessoryType = item.isFolder ? .detailDisclosureButton : .none
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard !busy else { return }
        let item = items[indexPath.row]
        if item.isFolder { folders.append(item); items = []; tableView.reloadData(); reload() }
        else { itemActions(item, row: indexPath) }
    }
    override func tableView(_ tableView: UITableView, accessoryButtonTappedForRowWith indexPath: IndexPath) { if !busy { itemActions(items[indexPath.row], row: indexPath) } }
    private func itemActions(_ item: OneDriveItem, row: IndexPath) {
        let alert = UIAlertController(title: item.name, message: nil, preferredStyle: .actionSheet)
        if !item.isFolder {
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
        alert.addAction(UIAlertAction(title: text("Umbenennen", "Rename"), style: .default) { [weak self] _ in self?.namePrompt(item: item) })
        alert.addAction(UIAlertAction(title: text("In OneDrive-Papierkorb verschieben", "Move to OneDrive recycle bin"), style: .destructive) { [weak self] _ in self?.confirmRecycle(item) })
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
                if let item { try await client.rename(item, to: name) }
                else { try await client.createFolder(name, parent: self.folders.last?.id) }
                try await self.load()
            }
        })
        alert.addAction(UIAlertAction(title: text("Abbrechen", "Cancel"), style: .cancel))
        present(alert, animated: true)
    }
    private func confirmRecycle(_ item: OneDriveItem) {
        let alert = UIAlertController(title: text("In den Papierkorb verschieben?", "Move to recycle bin?"), message: item.name, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: text("Verschieben", "Move"), style: .destructive) { [weak self] _ in
            self?.run { [weak self] in
                guard let self, let client = self.client else { return }
                try await client.recycle(item); try await self.load()
            }
        })
        alert.addAction(UIAlertAction(title: text("Abbrechen", "Cancel"), style: .cancel))
        present(alert, animated: true)
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if exportedURL != nil { cleanExport(); return }
        guard let url = urls.first else { return }
        run { [weak self] in
            guard let self, let client = self.client else { return }
            let scope = url.startAccessingSecurityScopedResource()
            defer { if scope { url.stopAccessingSecurityScopedResource() } }
            try await client.upload(url, parent: self.folders.last?.id)
            try await self.load()
        }
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
#endif
