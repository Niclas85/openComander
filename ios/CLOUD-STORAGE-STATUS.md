# macOS cloud browsing — 9 September 2026

## Implemented

- Discover all directory-based File Providers below `~/Library/CloudStorage`,
  including multiple Google Drive/OneDrive accounts and other provider names.
- Discover iCloud Drive and conventional legacy home-directory sync folders;
  resolve symlinks and deduplicate their targets.
- Label Google folders containing `.drive_fs_ignore_preserved_domain` as
  local archives, keep them accessible, and sort them after active locations.
- Load macOS file lists and tree children off the UI thread. Coordinate cloud
  directory reads with NSFileCoordinator, prefetch directory metadata, and
  reject outdated asynchronous results after navigation/refresh.
- Distinguish loading, slow response, empty directory and read failure. Failed
  listings clear stale rows and expose a Try Again button; Cmd-R also retries.
- Observe the current cloud folder through NSFilePresenter with debounced
  refreshes. Refresh cloud panes after app activation. Stop old observers on
  navigation/deinitialization.
- Do not automatically recursively calculate cloud-folder sizes.
- Explain provider setup, My Drive, archives, retries and custom sync folders
  in Help (German/English, fallback for other languages).

## Verification

- Signed arm64 Mac Catalyst Debug build: **PASS**.
- iOS Simulator Debug build, signing disabled: **PASS** (no iOS UI run).
- Native Foundation tests: **PASS** provider discovery, multiple accounts,
  legacy roots, symlink deduplication, broken links, preserved-domain labels,
  path boundaries, Unicode, hidden files, directory metadata, empty versus
  missing directory and real coordinated-change notification delivery.
- Read-only live metadata: active Google Drive contains one top-level folder,
  with **696** entries in `Meine Ablage`; iCloud Drive contains **5** folders.
- Installed `/Applications/OpenCommander.app`: Google Drive's 696 entries
  visibly load; iCloud folders and an existing nested audio filename display.
  Cloud sizes display a dash rather than launching an account-wide size scan.
  The old Google domain is visibly labeled as a local archive.
  A displayed Google JPEG was independently verified as `compressed,dataless`
  with `ls -lO`: online-only placeholders are included, without opening content.
- Visible local recovery test: open a synthetic folder, temporarily rename it
  outside the app, Cmd-R, verify explicit missing-folder error, restore it,
  press Try Again, verify its test file reappears.
- Installed app signature verification passes, with the same designated
  requirement as the previous installed build. Previous bundle backed up to
  `/tmp/OpenCommander-AppBackup.hpQlHE/OpenCommander.app`.

Run the native tests with Xcode's selected SDK:

```sh
xcrun --sdk macosx swiftc -swift-version 5 \
  ios/OpenCommander/MacFileSystem.swift ios/tests/CloudStorageTests/main.swift \
  -o /tmp/opencommander-cloud-tests
/tmp/opencommander-cloud-tests
# Optional: only list metadata in locally configured real provider folders.
/tmp/opencommander-cloud-tests --live-read-only
```

## Limits

Follow-up: the Google Drive account subsequently reported a provider failure
when opening online-only content. See [image preview findings](IMAGE-PREVIEW-STATUS.md).
Successful metadata listing does not establish that cloud contents can download.

OneDrive.app is installed on this Mac, but no OneDrive provider or conventional
home sync folder was exposed at test time. Its discovery is fixture-tested,
not a live signed-in OneDrive account test. Custom sync roots remain accessible
through Choose Other Folder. Installing a client alone is not a configured
cloud filesystem. This change does not implement provider login/synchronization,
Finder badges, pin/evict controls, Google web-document conversion, or independent
cloud APIs. Online-only content opening/copying and real-cloud write/conflict/
offline recovery tests remain separate work. No real cloud file contents or
external-drive data were modified in these tests.

References: [Google's File Provider integration](https://support.google.com/drive/answer/12178485?hl=de),
[Microsoft's Files On-Demand overview](https://support.microsoft.com/en-us/onedrive/save-disk-space-with-onedrive-files-on-demand-for-mac),
[Apple file coordination](https://developer.apple.com/documentation/foundation/nsfilecoordinator).
