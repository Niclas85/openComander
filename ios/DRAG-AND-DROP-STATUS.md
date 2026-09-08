# External drag and drop — 8 September 2026

This is an incremental implementation, **not complete Finder parity**.

## Implemented

- Incoming file URLs, files and directory representations from other apps.
- Outgoing physical files and folders expose both NSURL and a typed file
  representation, including directory drags from the tree.
- Drops onto a physical folder in either list/tree target that folder; empty
  list space targets the current directory. ZIP and read-only targets reject.
- Actual drag items determine internal transfers, not mutable selection state
  or a stale global source-pane reference.
- The Copy/Move toolbar choice is captured when the drop starts. External Move
  is explicit, and refused when the provider only supplies a temporary copy.
- Provider temporary files are copied to private staging **inside** their
  callback and held through conflict dialogs and file operations. Only owned
  staging is cleaned; security scopes are released explicitly.
- Existing Keep/Replace/Cancel, progress and undo paths are reused; concurrent
  drops during preparation/transfer/conflict dialogs are rejected.
- A nonresponding provider times out after two minutes; late completions cannot
  start a transfer. Preparation failures never delete source files.
- Enter/Cmd-C/Cmd-V/Delete/Space are no longer intercepted by file commands
  while editing the destination path or another text input.

## Verification

Signed arm64 Mac Catalyst debug build succeeds. Existing unrelated compiler
deprecation warnings remain. Native Foundation provider tests exercise
files/folders, Unicode, ordered multiple selection, duplicate removal,
temporary file and directory staging, unsafe suggested names, original
preservation, rejected web URLs, errors, raw file URLs and timeout handling.

```sh
xcrun swiftc -swift-version 5 ios/OpenCommander/FileDropTransfer.swift \
  ios/tests/FileDropTests/main.swift -o /tmp/opencommander-file-drop-tests
/tmp/opencommander-file-drop-tests
```

Visible path-field navigation was exercised successfully. A synthetic Finder
fixture was prepared at `/private/tmp/OpenCommander-DragUI.ZVs81E`, but the
actual cross-application mouse drag was **not run**: focus was changing to other
user tasks. Finder windows temporarily minimized for setup were restored;
the two test Finder windows were closed. No desktop files or external disks
were copied, moved or deleted. No production release was made.

## Still required

- Visible Finder → list, Finder → folder row/tree, OpenCommander → Finder,
  multi-file/folder, cancellation, conflicts, Move and undo regression tests.
- Actual provider applications, network/cloud volumes, and iPad Files testing.
- Finder-style same-volume default move, Option/Command drag overrides,
  spring-loaded folders and native cross-app move cursor negotiation. UIKit
  permits `.move` proposals only for allowed sessions; external imports use a
  `.copy` proposal while the explicit toolbar choice controls our file action.
  Do not describe this behavior as identical to Finder.
- Plain web links, aliases and extracting virtual ZIP entries by dragging are
  not implemented by this file-transfer change.

The app Help contains the Copy/Move procedure and these main limitations in
German and English (other languages fall back to English for the new entries).
