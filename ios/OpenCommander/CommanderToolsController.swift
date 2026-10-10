import UIKit

/// One native workflow for local disks and installed macOS File Providers.
final class CommanderToolsController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    enum Mode { case search, compare, rename }
    struct Row { let title: String; let detail: String; let url: URL? }
    let mode: Mode
    let root: URL
    let other: URL
    let selected: [URL]
    let hidden: Bool
    let initialQuery: String
    let german = L10n.currentLanguage.hasPrefix("de")
    var onOpen: ((URL) -> Void)?
    var onRename: (([FileUndoRecord]) -> Void)?
    var onlineRun: (@MainActor (String, Bool, String, [String]) async throws -> [Row])?
    var onlineApply: (@MainActor () async throws -> Int)?
    var displayRoot: String?
    var displayOther: String?
    private var onlineTask: Task<Void, Never>?
    func report(_ message: String) { status.text = message }
    private let cancellation = FileOperationCancellation()
    private let table = UITableView(frame: .zero, style: .plain)
    private let status = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let runButton = UIButton(type: .system)
    private let applyButton = UIButton(type: .system)
    private let fields = (0..<5).map { _ in UITextField() }
    private let searchPath = UITextField()
    private let caseSensitiveButton = UIButton(type: .system)
    private var rows: [Row] = []
    private var plan: [CommanderTools.Rename] = []
    private var busy = false
    private var closed = false

    init(mode: Mode, root: URL, other: URL, selected: [URL], hidden: Bool, query: String = "*") {
        self.mode = mode; self.root = root; self.other = other; self.selected = selected; self.hidden = hidden
        self.initialQuery = query
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func text(_ de: String, _ en: String) -> String { german ? de : en }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        isModalInPresentation = true
        let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20)])
        let heading = UILabel(); heading.font = .preferredFont(forTextStyle: .title2)
        heading.text = mode == .search ? text("Dateien suchen", "Find files") : mode == .compare ? text("Ordner vergleichen", "Compare folders") : text("Mehrfach umbenennen", "Multi-rename")
        stack.addArrangedSubview(heading)
        let info = UILabel(); info.numberOfLines = 0; info.font = .preferredFont(forTextStyle: .caption1)
        info.text = (displayRoot ?? root.path) + (mode == .compare ? "\n↔ " + (displayOther ?? other.path) : "") + "\n" + text("Unterordner werden einbezogen. Keine symbolischen Links verfolgen.", "Includes subfolders. Does not follow symbolic links.")
        if mode == .rename { info.text = text("[N] Name ohne Erweiterung · [E] Erweiterung mit Punkt · [C] Zähler\nVorschau vor Anwenden. Vorhandene Namen werden niemals ersetzt. Reihenfolge: Auswahl nach Name sortiert.", "[N] Base name · [E] Extension including dot · [C] Counter\nPreview before applying. Existing names are never replaced. Selection sorted by name.") }
        if mode == .rename && onlineRun != nil { info.text! += "\n" + text("Bei Abbruch bleiben abgeschlossene Umbenennungen in der Historie erhalten.", "On cancellation, completed renames remain in History.") }
        stack.addArrangedSubview(info)
        if mode == .search {
            info.text = text("Suche im angegebenen Ordner und seinen Unterordnern. Symbolischen Links wird nicht gefolgt.", "Searches the chosen folder and its subfolders. Does not follow symbolic links.")
            let pathRow = UIStackView(); pathRow.spacing = 12
            let label = UILabel(); label.text = text("Suchpfad", "Search folder")
            label.widthAnchor.constraint(equalToConstant: 210).isActive = true
            searchPath.borderStyle = .roundedRect; searchPath.text = root.path
            searchPath.accessibilityIdentifier = "CommanderSearchPath"
            searchPath.autocorrectionType = .no; searchPath.autocapitalizationType = .none
            searchPath.clearButtonMode = .whileEditing
            searchPath.addTarget(self, action: #selector(run), for: .editingDidEndOnExit)
            pathRow.addArrangedSubview(label); pathRow.addArrangedSubview(searchPath)
            stack.addArrangedSubview(pathRow)
        }
        if mode != .compare {
            let defaults = mode == .search ? [initialQuery] : ["[N][E]", "", "", "1", "3"]
            let labels = mode == .search ? [text("Dateiname (* und ? möglich)", "File name (* and ? allowed)")] : [text("Namensmuster", "Name pattern"), text("Suchen nach", "Find"), text("Ersetzen durch", "Replace with"), text("Zähler beginnt bei", "Counter starts at"), text("Zählerstellen (1–9)", "Counter digits (1–9)")]
            for i in defaults.indices {
                let line = UIStackView(); line.spacing = 12
                let label = UILabel(); label.text = labels[i]; label.widthAnchor.constraint(equalToConstant: 210).isActive = true
                fields[i].borderStyle = .roundedRect; fields[i].text = defaults[i]
                fields[i].autocorrectionType = .no; fields[i].autocapitalizationType = .none
                fields[i].accessibilityIdentifier = "CommanderToolField-\(i)"
                fields[i].addTarget(self, action: #selector(invalidatePlan), for: .editingChanged)
                if mode == .search { fields[i].addTarget(self, action: #selector(run), for: .editingDidEndOnExit) }
                line.addArrangedSubview(label); line.addArrangedSubview(fields[i]); stack.addArrangedSubview(line)
            }
        }
        if mode == .search {
            caseSensitiveButton.setTitle(text(" Groß-/Kleinschreibung beachten", " Match case"), for: .normal)
            caseSensitiveButton.setImage(UIImage(systemName: "square"), for: .normal)
            caseSensitiveButton.setImage(UIImage(systemName: "checkmark.square.fill"), for: .selected)
            caseSensitiveButton.isSelected = false
            caseSensitiveButton.contentHorizontalAlignment = .leading
            caseSensitiveButton.accessibilityIdentifier = "CommanderSearchMatchCase"
            caseSensitiveButton.accessibilityValue = text("Abgewählt", "Unchecked")
            caseSensitiveButton.addTarget(self, action: #selector(toggleSearchCase), for: .touchUpInside)
            stack.addArrangedSubview(caseSensitiveButton)
        }
        let controls = UIStackView(); controls.spacing = 20
        runButton.setTitle(mode == .rename ? text("Vorschau", "Preview") : text("Starten", "Start"), for: .normal)
        runButton.accessibilityIdentifier = "CommanderToolRun"
        runButton.addTarget(self, action: #selector(run), for: .touchUpInside); controls.addArrangedSubview(runButton)
        if mode == .rename {
            applyButton.setTitle(text("Umbenennen anwenden", "Apply rename"), for: .normal)
            applyButton.accessibilityIdentifier = "CommanderToolApply"; applyButton.isEnabled = false
            applyButton.addTarget(self, action: #selector(apply), for: .touchUpInside); controls.addArrangedSubview(applyButton)
        }
        let cancel = UIButton(type: .system); cancel.setTitle(text("Abbrechen / Schließen", "Cancel / Close"), for: .normal)
        cancel.accessibilityIdentifier = "CommanderToolClose"
        cancel.addTarget(self, action: #selector(close), for: .touchUpInside); controls.addArrangedSubview(cancel)
        controls.addArrangedSubview(spinner); stack.addArrangedSubview(controls)
        status.numberOfLines = 0; status.accessibilityIdentifier = "CommanderToolStatus"; stack.addArrangedSubview(status)
        table.dataSource = self; table.delegate = self; table.accessibilityIdentifier = "CommanderToolResults"
        table.rowHeight = UITableView.automaticDimension; table.estimatedRowHeight = 72
        stack.addArrangedSubview(table)
    }
    @objc private func invalidatePlan() {
        plan = []; applyButton.isEnabled = false
        if onlineRun != nil { rows = []; table.reloadData() }
    }
    @objc private func toggleSearchCase() {
        caseSensitiveButton.isSelected.toggle()
        caseSensitiveButton.accessibilityValue = caseSensitiveButton.isSelected
            ? text("Ausgewählt", "Checked") : text("Abgewählt", "Unchecked")
        if caseSensitiveButton.isSelected { caseSensitiveButton.accessibilityTraits.insert(.selected) }
        else { caseSensitiveButton.accessibilityTraits.remove(.selected) }
    }
    private func setBusy(_ value: Bool) {
        busy = value; runButton.isEnabled = !value
        fields.forEach { $0.isEnabled = !value }
        searchPath.isEnabled = !value
        caseSensitiveButton.isEnabled = !value
        applyButton.isEnabled = !value && (!plan.isEmpty || (onlineApply != nil && !rows.isEmpty))
        if value { spinner.startAnimating(); status.text = text("Wird verarbeitet … Cloud-Dateien werden ggf. heruntergeladen.", "Working … Cloud files may need to download.") }
        else { spinner.stopAnimating() }
    }
    @objc private func close() {
        if busy {
            cancellation.cancel(); onlineTask?.cancel(); status.text = text("Wird abgebrochen …", "Cancelling …")
            return // wait for I/O/rollback before allowing another operation
        }
        closed = true; dismiss(animated: true)
    }
    @objc private func run() {
        guard !busy else { return }
        view.endEditing(true); invalidatePlan(); cancellation.reset(); rows = []; table.reloadData()
        let query = (fields[0].text ?? "*").precomposedStringWithCanonicalMapping
        let caseSensitive = caseSensitiveButton.isSelected
        guard mode != .search || !query.isEmpty else { status.text = text("Bitte Suchmuster eingeben.", "Enter a search pattern."); return }
        if let onlineRun {
            let path = searchPath.text ?? root.path, values = fields.map { $0.text ?? "" }
            setBusy(true)
            onlineTask = Task { @MainActor in
                do {
                    self.rows = try await onlineRun(query, caseSensitive, path, values)
                    self.setBusy(false); self.table.reloadData()
                    self.status.text = "\(self.rows.count) " + self.text("Einträge", "entries")
                } catch { self.failed(error) }
            }
            return
        }
        let searchRoot: URL
        if mode == .search {
            guard let directory = CommanderTools.searchDirectory(searchPath.text ?? "") else {
                status.text = text("Bitte einen vollständigen Ordnerpfad eingeben (z. B. /Users/… oder ~/Downloads).", "Enter an absolute folder path (for example /Users/… or ~/Downloads).")
                return
            }
            searchRoot = directory
        } else { searchRoot = root }
        let rule = CommanderTools.RenameRule(pattern: fields[0].text ?? "", find: fields[1].text ?? "", replacement: fields[2].text ?? "", start: Int(fields[3].text ?? "") ?? -1, digits: Int(fields[4].text ?? "") ?? 0)
        setBusy(true)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                var rows: [Row] = []; var warnings: [String] = []; var plan: [CommanderTools.Rename] = []
                switch self.mode {
                case .search:
                    let result = try CommanderTools.search(searchRoot, query: query, hidden: self.hidden,
                                                           caseSensitive: caseSensitive, cancel: self.cancellation)
                    rows = result.urls.map { Row(title: $0.lastPathComponent, detail: $0.path, url: $0) }; warnings = result.warnings
                case .compare:
                    let result = try CommanderTools.compare(self.root, self.other, hidden: self.hidden, cancel: self.cancellation)
                    rows = result.rows.map { item in
                        let label: String
                        switch item.state {
                        case .equal: label = self.text("Gleich", "Equal")
                        case .different: label = self.text("Unterschiedlich", "Different")
                        case .leftOnly: label = self.text("Nur links", "Left only")
                        case .rightOnly: label = self.text("Nur rechts", "Right only")
                        case .unreadable: label = self.text("Nicht lesbar / verändert", "Unreadable / changed")
                        }
                        return Row(title: label + " · " + item.path, detail: item.detail, url: nil)
                    }; warnings = result.warnings
                case .rename:
                    plan = try CommanderTools.renamePlan(self.selected, rule: rule)
                    rows = plan.map { Row(title: $0.source.lastPathComponent + " → " + $0.destination.lastPathComponent, detail: $0.source.deletingLastPathComponent().path, url: nil) }
                }
                DispatchQueue.main.async {
                    guard !self.closed else { return }
                    self.plan = plan; self.rows = rows; self.setBusy(false); self.table.reloadData()
                    self.status.text = "\(rows.count) " + self.text("Einträge", "entries") + (warnings.isEmpty ? "" : "\n⚠ " + warnings.prefix(5).joined(separator: "\n") + "\n" + self.text("Ergebnis unvollständig.", "Incomplete result."))
                }
            } catch { self.failed(error) }
        }
    }
    @objc private func apply() {
        if let onlineApply, !busy, !rows.isEmpty {
            rows = []; table.reloadData(); setBusy(true)
            onlineTask = Task { @MainActor in
                do {
                    let count = try await onlineApply()
                    self.setBusy(false); self.status.text = "\(count) " + self.text("umbenannt. Rückgängig über den Hauptknopf.", "renamed. Undo using the main button.")
                } catch { self.failed(error) }
            }
            return
        }
        guard !busy, !plan.isEmpty else { return }
        let plan = self.plan; self.plan = []; cancellation.reset(); setBusy(true)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let records = try CommanderTools.rename(plan, cancel: self.cancellation)
                DispatchQueue.main.async {
                    self.onRename?(records); self.setBusy(false)
                    self.status.text = "\(records.count) " + self.text("umbenannt. Rückgängig über die Historie.", "renamed. Undo through History.")
                }
            } catch { self.failed(error) }
        }
    }
    private func failed(_ error: Error) {
        DispatchQueue.main.async {
            self.plan = []; self.rows = []; self.table.reloadData(); self.setBusy(false)
            let ns = error as NSError
            self.status.text = "⚠ " + (error is CancellationError ? self.text("Abgebrochen. Abgeschlossene Schritte bleiben erhalten.", "Cancelled. Completed steps remain.") : ns.domain == "OpenCommander.Remote" ? L10n.get(ns.localizedDescription) : HistoryFailure(error).message)
        }
    }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let row = rows[indexPath.row]; cell.textLabel?.text = row.title; cell.detailTextLabel?.text = row.detail
        cell.textLabel?.numberOfLines = 0
        cell.detailTextLabel?.numberOfLines = 0
        cell.detailTextLabel?.lineBreakMode = .byCharWrapping
        cell.accessibilityIdentifier = "CommanderToolResult-\(indexPath.row)"
        if row.url != nil { cell.accessoryType = .disclosureIndicator }
        return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard !busy, let url = rows[indexPath.row].url else { return }
        closed = true; dismiss(animated: true) { self.onOpen?(url) }
    }
}
