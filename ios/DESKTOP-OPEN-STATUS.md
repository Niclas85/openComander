# macOS default-application opening — 9 September 2026

The Mac Catalyst app now delegates file opening to public AppKit NSWorkspace
APIs through the signed, embedded OpenCommanderMacBridge native bundle.
Double-click, Command-O and Command-Down use the system's default application,
without an image-only extension allowlist. Ordinary directories navigate inside
OpenCommander; document/application packages and ZIP files use their system
handler. Their contents remain accessible through the tree/context menu.

The context menu offers Open With (a native application picker, without changing
default associations), Preview, and Browse Contents where applicable. Space and
Command-Y invoke Quick Look separately; preview support depends on Quick Look.
The in-app Help explains these distinctions.

Physical URLs are handed directly to the chosen application, including cloud
URLs. Successful handoff does not guarantee successful decoding or downloading.
ZIP members are extracted to unique temporary directories; edits to those copies
are not written back into the ZIP. Preparation runs asynchronously with a timeout.

## Verification

- Signed Mac Catalyst and unsigned iOS Simulator builds: PASS.
- Native bridge principal-class/shared-protocol load: PASS.
- Visible double-click tests from installed OpenCommander: TXT → TextEdit;
  JPG, PNG and PDF → Preview; MP4 → QuickTime; RTFD package → TextEdit: PASS.
- Unknown extension: default-open error displayed; Open With → TextEdit opened
  the synthetic content: PASS.
- Selected PDF + Space: native Quick Look panel with the correct filename: PASS.
- DOCX → Pages and WAV → Music: application handoff observed, but their first-run
  license/setup screens prevented content verification. No terms were accepted.
- ZIP default opening, every possible document format, and cloud content opening
  are not claimed as runtime-tested. A compatible, initialized app is required.
- Google Drive still independently reports an account/provider failure; see
  IMAGE-PREVIEW-STATUS.md. No Drive reset or permission reset was performed.

All content-open tests used synthetic local files. Existing user documents,
external disks, file associations and unrelated application windows were preserved.
The update is installed at /Applications/OpenCommander.app with the same signing
identity/designated requirement. No commit or push was performed for this change.

The fixture/protocol test source is tests/DesktopOpenTests/main.swift.
