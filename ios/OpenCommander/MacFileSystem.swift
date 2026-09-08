import Foundation

#if targetEnvironment(macCatalyst)
import Darwin
#endif

enum HostFileSystem {
    enum StorageKind {
        case externalDrive
        case networkShare
        case cloudStorage
    }

    struct StorageLocation {
        let name: String
        let url: URL
        let kind: StorageKind
    }

    enum FullDiskAccessStatus: Equatable {
        case granted
        case denied
        case unavailable
    }

    static var homeDirectory: URL {
#if targetEnvironment(macCatalyst)
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

        let cloudRoot = homeDirectory.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        let cloudProviders = (try? fm.contentsOfDirectory(
            at: cloudRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for provider in cloudProviders {
            let values = try? provider.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true || values?.isSymbolicLink == true else { continue }
            append(provider, name: cloudDisplayName(provider.lastPathComponent), kind: .cloudStorage)
        }

        let iCloudDrive = homeDirectory.appendingPathComponent(
            "Library/Mobile Documents/com~apple~CloudDocs",
            isDirectory: true
        )
        append(iCloudDrive, name: "iCloud Drive", kind: .cloudStorage)

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
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
#else
        return []
#endif
    }

    private static func cloudDisplayName(_ directoryName: String) -> String {
        let knownPrefixes: [(String, String)] = [
            ("GoogleDrive-", "Google Drive — "),
            ("OneDrive-", "OneDrive — "),
            ("Dropbox-", "Dropbox — "),
            ("Box-", "Box — ")
        ]
        for (prefix, replacement) in knownPrefixes where directoryName.hasPrefix(prefix) {
            return replacement + String(directoryName.dropFirst(prefix.count))
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
