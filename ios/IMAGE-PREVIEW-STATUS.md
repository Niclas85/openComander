# Image previews — 9 September 2026

Later macOS update: double-click now opens **all file types in their system
default application**, including images. The internal image viewer remains on
iOS; macOS has separate Quick Look preview. See DESKTOP-OPEN-STATUS.md for the
current behavior and verification. The cloud-provider diagnosis below remains
applicable regardless of the viewing application.

## Cause and fix

The internal image viewer incorrectly used the localized "No app found" message
for every read or decode failure. The reported Google Drive JPEG was an
online-only (`dataless`) file. Direct ImageIO URL loading returned nil without
exposing the underlying File Provider error.

ImagePreviewLoader now holds security-scoped and coordinated read access while
obtaining and decoding file data. The coordinator can request online content
from a working provider. The viewer shows loading/slow-download feedback,
reports provider/access errors separately from invalid images, and offers retry.
Closing/switching cancels coordination and invalidates old UI completions.
Thumbnails remain bounded to the requested display resolution. ZIP preparation
uses the coordinated source URL instead of the pre-coordination URL.

## Verified

- Native tests: JPEG and PNG thumbnail decoding, Unicode/uppercase extension,
  bounded dimensions, corrupt image, missing file, preparation error propagation
  and use of the prepared URL: PASS.
- Signed Mac Catalyst and unsigned iOS Simulator builds: PASS.
- Installed `/Applications/OpenCommander.app`, same designated requirement:
  local JPG and PNG visibly rendered; corrupt PNG showed a decode-specific
  error; replacing only that synthetic test file and pressing Try Again visibly
  rendered the repaired image. No external image app was needed.
- The reported Google Drive JPEG now visibly shows a cloud-provider error
  (`-1004`) with Try Again, rather than the unrelated "No app found" message.

## External blocker: Google Drive

A coordinated read of the reported cloud image returned
`NSFileProviderErrorDomain -1004` (`serverUnreachable`). Google Drive's own UI
independently reported that the account could not load or continue syncing and
offered **Reset local data** / **Later**. Neither button was pressed. No account,
cloud content, sync database or cache was reset, deleted or reconfigured.

Cloud filenames can remain visible while their contents cannot be downloaded.
Successful online-only image rendering on this account remains unverified until
the Google Drive account issue is repaired. Resetting local Drive data requires
separate consent and checking/backing up unsynced local files first.

## Test command

```sh
xcrun --sdk macosx swiftc -swift-version 5 \
  ios/OpenCommander/ImagePreviewLoader.swift ios/tests/ImagePreviewTests/main.swift \
  -o /tmp/opencommander-image-tests
/tmp/opencommander-image-tests
```

Optional `--keep-fixture` retains synthetic UI test images; `--read-image PATH`
attempts an explicitly selected real image (may download its contents). Provider
failure is reported as `LIVE BLOCKED`, not a successful content-open test.

Apple documents [coordinated placeholder reads and downloads](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/DocumentPickerProgrammingGuide/CreatinganOutstandingUserExperience/CreatinganOutstandingUserExperience.html).
