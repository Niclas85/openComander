import Foundation

struct DesktopLocationPreference: Codable {
    var path: String
    var name: String
    var enabled: Bool
    var custom: Bool
    var bookmark: Data?
    var visibilityConfigured: Bool?
}

enum DesktopLocationPreferences {
    static let oneDriveOnlinePath = "onedrive://online"
    static func load(from defaults: UserDefaults = .standard) -> [DesktopLocationPreference] {
        guard let data = defaults.data(forKey: "desktop_locations_v1") else { return [] }
        return (try? JSONDecoder().decode([DesktopLocationPreference].self, from: data)) ?? []
    }

    static func save(_ entries: [DesktopLocationPreference], to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: "desktop_locations_v1") }
    }
}

#if targetEnvironment(macCatalyst) || os(macOS)
import Darwin
#endif

enum HostFileSystem {
    static func coordinatedRead<T>(at url: URL, _ read: (URL) throws -> T) throws -> T {
#if targetEnvironment(macCatalyst) || os(macOS)
        let scope = url.startAccessingSecurityScopedResource()
        defer { if scope { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { coordinatedURL in
            result = Result { try read(coordinatedURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
#else
        return try read(url)
#endif
    }
    enum StorageKind {
        case externalDrive
        case networkShare
        case cloudStorage
    }

    struct StorageLocation {
        let name: String
        let url: URL
        let kind: StorageKind
        var isLocalArchive: Bool = false
        var isDisabled: Bool = false
        var visibleByDefault: Bool { !isLocalArchive && !isDisabled }
        var previousDefaultNames: [String] {
            let component = url.lastPathComponent
            if component.hasPrefix("OneDrive-FreigegebeneBibliotheken") {
                return ["OneDrive — " + String(component.dropFirst("OneDrive-".count))]
            }
            return []
        }

        var displayName: String {
            if isLocalArchive { return "\(name) — \(L10n.get("cloud_local_archive"))" }
            if isDisabled { return "\(name) — \(L10n.get("location_disabled"))" }
            return name
        }
    }

    enum FullDiskAccessStatus: Equatable {
        case granted
        case denied
        case unavailable
    }

    static var homeDirectory: URL {
#if targetEnvironment(macCatalyst) || os(macOS)
        if let passwordEntry = getpwuid(getuid()),
           let home = passwordEntry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: home), isDirectory: true)
        }
#endif
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var downloadsDirectory: URL {
        homeDirectory.appendingPathComponent("Downloads", isDirectory: true)
    }

    static var desktopDirectory: URL {
        homeDirectory.appendingPathComponent("Desktop", isDirectory: true)
    }

    /// Finds storage already made available by macOS. Cloud File Provider services
    /// live below Library/CloudStorage, while removable media and mounted network
    /// shares normally live below /Volumes. The direct /Volumes scan is necessary
    /// because Mac Catalyst does not always report every mounted share through
    /// `mountedVolumeURLs`.
    static func availableStorageLocations() -> [StorageLocation] {
#if targetEnvironment(macCatalyst)
        var result: [StorageLocation] = []
        var addedPaths = Set<String>()
        let fm = FileManager.default
        let volumeKeys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeIsLocalKey,
            .volumeIsInternalKey,
            .volumeIsRemovableKey
        ]

        func append(_ url: URL, name: String? = nil, kind: StorageKind) {
            let normalized = url.standardizedFileURL
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: normalized.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  addedPaths.insert(normalized.path).inserted else { return }
            result.append(StorageLocation(name: name ?? normalized.lastPathComponent, url: normalized, kind: kind))
        }

        let reportedVolumes = fm.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(volumeKeys),
            options: []
        ) ?? []
        for volume in reportedVolumes where volume.standardizedFileURL.path.hasPrefix("/Volumes/") {
            let values = try? volume.resourceValues(forKeys: volumeKeys)
            let kind: StorageKind = values?.volumeIsLocal == false ? .networkShare : .externalDrive
            append(volume, name: values?.volumeName, kind: kind)
        }

        let volumesDirectory = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        let directlyVisibleVolumes = (try? fm.contentsOfDirectory(
            at: volumesDirectory,
            includingPropertiesForKeys: Array(volumeKeys) + [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for volume in directlyVisibleVolumes {
            let values = try? volume.resourceValues(forKeys: volumeKeys)
            let kind: StorageKind = values?.volumeIsLocal == false ? .networkShare : .externalDrive
            append(volume, name: values?.volumeName, kind: kind)
        }

        result.append(contentsOf: cloudStorageLocations(in: homeDirectory).filter {
            addedPaths.insert($0.url.standardizedFileURL.path).inserted
        })

        let order: (StorageKind) -> Int = {
            switch $0 {
            case .externalDrive: return 0
            case .networkShare: return 1
            case .cloudStorage: return 2
            }
        }
        return result.sorted {
            let leftOrder = order($0.kind)
            let rightOrder = order($1.kind)
            if leftOrder != rightOrder { return leftOrder < rightOrder }
            if $0.isLocalArchive != $1.isLocalArchive { return !$0.isLocalArchive }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
#else
        return []
#endif
    }

    /// Discover provider-published folders, not app bundles: an installed client
    /// without a signed-in/syncing account does not expose a filesystem to browse.
    /// Keep preserved Google domains accessible, but never present them as live accounts.
    static func cloudStorageLocations(in home: URL) -> [StorageLocation] {
        let fm = FileManager.default
        var result: [StorageLocation] = []
        var addedPaths = Set<String>()
        func append(_ url: URL, name: String) {
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard isDirectory(resolved), addedPaths.insert(resolved.path).inserted else { return }
            let datedGoogleCopy = resolved.lastPathComponent.hasPrefix("GoogleDrive-") &&
                resolved.lastPathComponent.range(of: #" \(\d{2}\.\d{2}\.\d{2} \d{2}:\d{2}\)$"#, options: .regularExpression) != nil
            let archived = datedGoogleCopy || fm.fileExists(atPath: resolved.appendingPathComponent(".drive_fs_ignore_preserved_domain").path)
            var disabled = false
            // Only inspect the top-level names; never hydrate files or recurse.
            // Permission/transient errors do not mean a provider is disabled.
            if !archived {
                do { _ = try coordinatedRead(at: resolved) { try fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) } }
                catch { disabled = isDisabledProvider(error as NSError) }
            }
            result.append(StorageLocation(name: name, url: resolved, kind: .cloudStorage,
                isLocalArchive: archived, isDisabled: disabled))
        }

        let cloudRoot = home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        let cloudProviders = (try? fm.contentsOfDirectory(
            at: cloudRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for provider in cloudProviders {
            let values = try? provider.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true || values?.isSymbolicLink == true else { continue }
            append(provider, name: cloudDisplayName(provider.lastPathComponent))
        }

        let iCloudDrive = home.appendingPathComponent(
            "Library/Mobile Documents/com~apple~CloudDocs",
            isDirectory: true
        )
        append(iCloudDrive, name: "iCloud Drive")
        // Dropbox's sync folder may have been moved outside the home directory.
        if let data = try? Data(contentsOf: home.appendingPathComponent(".dropbox/info.json")),
           let accounts = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            for account in accounts.values {
                if let path = account["path"] as? String, path.hasPrefix("/") {
                    append(URL(fileURLWithPath: path, isDirectory: true), name: "Dropbox")
                }
            }
        }

        // Older sync clients and user-visible links can live in the home folder.
        // Resolve links before deduplication; never recursively search private app data.
        let homeChildren = (try? fm.contentsOfDirectory(at: home,
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for folder in homeChildren {
            let name = folder.lastPathComponent
            if ["OneDrive", "Dropbox", "Google Drive", "Box"].contains(name) ||
                name.hasPrefix("OneDrive - ") || name.hasPrefix("OneDrive-") || name.hasPrefix("GoogleDrive-") {
                append(folder, name: cloudDisplayName(name))
            }
        }
        return result.sorted {
            if $0.isLocalArchive != $1.isLocalArchive { return !$0.isLocalArchive }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func isDirectory(_ url: URL) -> Bool {
        // File Provider placeholders expose their type as URL metadata even when
        // no content is downloaded. Fall back to stat for ordinary symlinks.
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return true }
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    static func isCloudStorage(_ url: URL, home: URL = homeDirectory) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let roots = ["Library/CloudStorage", "Library/Mobile Documents"].map {
            home.appendingPathComponent($0).resolvingSymlinksInPath().standardizedFileURL.path
        }
        if roots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return true }
        let homePath = home.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard path.hasPrefix(homePath), let first = path.dropFirst(homePath.count).split(separator: "/").first else { return false }
        return ["OneDrive", "Dropbox", "Google Drive", "Box"].contains(String(first)) ||
            first.hasPrefix("OneDrive - ") || first.hasPrefix("OneDrive-") || first.hasPrefix("GoogleDrive-")
    }

    static func directoryContents(at url: URL, showHidden: Bool) throws -> [URL] {
        let read: (URL) throws -> [URL] = { directory in
            try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
                options: showHidden ? [] : [.skipsHiddenFiles])
        }
#if targetEnvironment(macCatalyst) || os(macOS)
        if isCloudStorage(url) {
            // Run off the UI thread. Coordinate the directory listing with its
            // provider; do not read file contents or recursively hydrate the drive.
            var coordinationError: NSError?
            var result: Result<[URL], Error>?
            NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges,
                error: &coordinationError) { coordinatedURL in
                    result = Result { try read(coordinatedURL) }
                }
            if let coordinationError { throw coordinationError }
            guard let result else { throw CocoaError(.fileReadUnknown) }
            return try result.get()
        }
#endif
        return try read(url)
    }

    static func cloudClientName(for url: URL) -> String? {
        let components = url.standardizedFileURL.pathComponents
        for (prefix, name) in [("OneDrive", "OneDrive"), ("GoogleDrive", "Google Drive"),
                               ("Dropbox", "Dropbox"), ("Box-", "Box")] {
            if components.contains(where: { $0.hasPrefix(prefix) }) { return name }
        }
        return nil
    }

    static func isDisabledProvider(_ error: NSError) -> Bool {
        // NSFileProviderErrorDomainDisabled: the OS reports a user-disabled domain.
        if error.domain == "NSFileProviderErrorDomain" && error.code == -2011 { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { return isDisabledProvider(underlying) }
        return false
    }

    private static func cloudDisplayName(_ directoryName: String) -> String {
        let knownPrefixes: [(String, String)] = [
            ("GoogleDrive-", "Google Drive — "),
            ("OneDrive-", "OneDrive — "),
            ("Dropbox-", "Dropbox — "),
            ("Box-", "Box — ")
        ]
        for (prefix, replacement) in knownPrefixes where directoryName.hasPrefix(prefix) {
            let account = String(directoryName.dropFirst(prefix.count))
            if prefix == "OneDrive-", account.hasPrefix("FreigegebeneBibliotheken") {
                return L10n.get("onedrive_shared_local")
            }
            return replacement + account
        }
        return directoryName
    }

    /// macOS has no public API that returns the Full Disk Access switch. Reading one of
    /// the user's TCC-protected Library folders is the established fail-closed probe.
    /// The probe never creates, changes, or uploads a file.
    static func fullDiskAccessStatus() -> FullDiskAccessStatus {
#if targetEnvironment(macCatalyst)
        let protectedDirectories = ["Mail", "Safari", "Messages"].map {
            homeDirectory.appendingPathComponent("Library/\($0)", isDirectory: true)
        }
        var sawPermissionDenial = false
        for directory in protectedDirectories {
            do {
                _ = try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
                return .granted
            } catch {
                let nsError = error as NSError
                let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
                if nsError.code == NSFileReadNoPermissionError ||
                    (underlying?.domain == NSPOSIXErrorDomain &&
                     (underlying?.code == Int(EACCES) || underlying?.code == Int(EPERM))) {
                    sawPermissionDenial = true
                }
            }
        }
        return sawPermissionDenial ? .denied : .unavailable
#else
        return .unavailable
#endif
    }
}

#if targetEnvironment(macCatalyst) || os(macOS)
/// Observe only the folder the user is browsing, not an entire cloud account.
/// Its owner must stop registration explicitly: NSFileCoordinator retains presenters.
final class CloudDirectoryObserver: NSObject, NSFilePresenter {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private let onChange: () -> Void

    init(url: URL, onChange: @escaping () -> Void) {
        presentedItemURL = url
        self.onChange = onChange
        super.init()
        NSFileCoordinator.addFilePresenter(self)
    }

    func stop() { NSFileCoordinator.removeFilePresenter(self) }
    func presentedItemDidChange() { onChange() }
    func presentedSubitemDidAppear(at url: URL) { onChange() }
    func presentedSubitemDidChange(at url: URL) { onChange() }
    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { onChange() }
    func presentedItemDidMove(to newURL: URL) { onChange() }
    func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping (Error?) -> Void) {
        completionHandler(nil)
        onChange()
    }
}
#endif
