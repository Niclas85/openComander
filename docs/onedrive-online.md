# OneDrive online (macOS, experimental)

OpenCommander now embeds its native online browser in the active left or right pane
under **Settings → OneDrive online** or the **OneDrive online** location shortcut.
The OneDrive recovery button also opens this screen. It uses Microsoft Graph, not the
local File Provider folder, and does not depend on the OneDrive sync application.

The macOS locations bar also offers **OneDrive online** directly. Under
**Settings / Locations**, users can rename or hide this shortcut and local locations,
or add their own folder shortcuts. Desktop and Documents are included as standard
locations. Disabled local providers and preserved Google Drive archives are hidden
by default, but remain identifiable and selectable in settings. Changing these
shortcuts never changes the provider account or deletes files.

## One-time developer setup

The developer-owned OpenCommander registration is now bundled using public client ID
`215df982-ff55-4272-9125-beacc651b2c3`. Users only need to select **Actions → Connect to
Microsoft**, sign in and review the permissions. A website login alone is not an OAuth
grant to OpenCommander. No secret or browser credential is bundled.

The following steps document the registration and are only needed to replace it with
another developer-owned registration:

1. Open the [Microsoft Entra admin center](https://entra.microsoft.com/), select
   **App registrations → New registration**, name it **OpenCommander**.
2. Select **Accounts in any organizational directory and personal Microsoft accounts**
   (or personal Microsoft accounts only for a personal-only registration).
3. Under **Authentication → Advanced settings**, enable **Allow public client flows**.
   This prototype uses the device authorization flow, which does not require a redirect URI.
4. Under **API permissions**, add delegated Microsoft Graph **Files.ReadWrite**.
   The login additionally requests **offline_access** for a renewable session.
   Do not add application permissions or create a client secret.
5. Copy **Application (client) ID** (a public UUID). In OpenCommander, choose
   **Settings → OneDrive online → Actions → Configure Microsoft app**, paste it and save.
6. Open the Microsoft verification page shown by the app, enter the displayed code,
   select your account and review/approve the requested access yourself.

An organization may restrict app registrations, consent or device-code sign-in; its
administrator must resolve that restriction. Creating a new tenant/subscription and
accepting Microsoft terms are not automated by OpenCommander.

For a distributed release, the developer should ship its own registered public client ID
using the `OneDriveClientID` Info.plist key; users should only need to connect their account.
Never ship a client secret in this desktop application.

## Current capabilities and limits

- Lists the connected account's primary drive, including all paginated children.
- Opens folders, refreshes, downloads an individual file through a Save dialog.
- Uploads files and recursive folders. Files over 10 MiB use sequential upload-session
  chunks; existing destinations are refused, never silently replaced.
- Creates folders, renames entries and moves selected entries to the OneDrive recycle bin
  after explicit confirmation.
- Stores renewable credentials in macOS Keychain, not preferences or logs. Disconnect
  removes the saved credential for the currently configured app ID without deleting files.
- The active pane hosts online navigation and OneDrive actions. Close returns to its
  previous local folder; selecting a local location also leaves online mode. Refresh
  and New Folder route to OneDrive. Local selection/clipboard/transfer commands never
  treat remote items or the pane's previous directory as cloud destinations.
- Online panes use the same tree/file-column structure, palette, 44-point rows,
  Name/Size/Type/Date columns, single-click selection and double-click folder opening
  as local panes. The tree loads folder children on navigation rather than scanning
  the whole account. Back/forward/parent history, name filtering and sorting operate
  on the remote view without converting Graph item IDs into filesystem paths.
- Preview and opening download a temporary local copy, then use the same media viewer,
  Quick Look or associated application as physical files. Remote file providers export
  file/folder representations to Finder and compatible apps without deleting sources.
- Supports multiple selection, Command-C/X/V/A/D/I, Space/Command-Y, F5/F6 and the
  normal pane-transfer controls. Drops on folder rows in the list/tree target that folder;
  empty space targets the current directory. Explicit Copy/Move toolbar mode applies.
- Within OneDrive, moves use Graph's server-side parent update. Recursive transfers
  between local and online panes stage the destination first. Cross-storage moves retain
  sources on failure/version change; local originals are trashed only after verified upload,
  online files are conditionally recycled only after successful local materialization.
  When moving an online folder to a local volume, the folder is copied but its online
  source is retained with an explicit warning: Graph cannot atomically guard concurrent
  descendant edits during a recursive deletion. Review and recycle it explicitly.
  Partial destination folders may remain after an interrupted upload; refresh before retrying.
- ZIP creation and safe extraction use the regular toolbar and publish their outputs
  into the current online folder. Extraction checks paths, expanded-size limits and CRCs
  before uploading; existing names get a numbered new destination.
- Rename and internal OneDrive moves can be undone in the current session. Undo is
  conditional on the version recorded after the operation; concurrent changes fail
  rather than being silently overwritten. Deleted items remain recoverable through
  OneDrive's recycle bin, not this session undo stack. Completed remote actions now
  appear in the normal persisted history, with completion time and source/destination
  locations. These are audit entries, not local undo buttons; remote rename/move undo
  still uses the current online session's Undo control. Upload/copy/ZIP undo is not
  implemented yet. Shared-library discovery,
  multi-account UI, Finder modifier-key/spring-loaded drop behavior and resumable retry
  after a failed upload session are not implemented. Links/special files are refused;
  folder transfer traversal is limited to 100 levels/100,000 entries.
- Pending online requests and local cloud directory listings display a pane-local
  activity indicator. Online transfers additionally show a cancellable global
  indeterminate progress indicator: no fabricated percentage when Graph does not
  provide byte progress. Google Drive/iCloud background synchronization outside
  OpenCommander remains owned by the provider app, not this indicator.
- This does not enable or repair a disabled macOS File Provider domain. Local cloud
  locations continue to use the existing provider integration.

The Microsoft registration and personal-account consent have been verified live.
The first token-save attempt exposed a missing Mac Catalyst Keychain entitlement
(`errSecMissingEntitlement`, -34018). The macOS target now supplies its application ID,
team ID and private Keychain access group, and the development build contains an
Xcode-generated provisioning profile. Builds that need a new development profile
require Xcode's `-allowProvisioningUpdates` with the developer's configured account.
Do not replace secure token storage with preferences to work around signing errors.

The corrected build is installed. Live personal-account authentication, root listing,
opening a nonempty subfolder, secure credential storage and automatic token refresh
after fully quitting/relaunching OpenCommander were verified on 2026-10-04.
No further login prompt was required after relaunch. At that stage cloud write
operations had only been tested against mocked Microsoft responses.
On 2026-10-05 the installed Mac build was additionally verified with online listings
embedded in both active panes, nonempty subfolder navigation, return to the preserved
local folder and disabled local rename/delete/ZIP actions while online mode is active.
The subsequent tree-layout build was checked live for nested folder expansion,
nonempty folder navigation, back history, double-click opening, ascending/descending
name sorting, filtering to zero matches and clearing the filter. Remote selection now
routes the main Rename/Delete controls to OneDrive's existing rename/recycle dialogs.
The file-action build additionally passed a live read-only Quick Look preview through
the main Preview button and Command-C/Command-V from the online list into an isolated
local temporary folder (downloaded file visible in the destination; online source
preserved). Default metadata is
used for the Graph download URL annotation; selecting it as a normal property omitted
the annotation on the personal account. The expanded mocked test covers large-file
chunks, no bearer on preauthenticated upload URLs, unexpected offsets, recursive folder
uploads, real root IDs for moves, descendant guards, source fingerprints and conditional
deletion failures. On 2026-10-05 the user additionally authorized a disposable
`OpenCommander-Funktionstest` folder. Recursive local-to-online upload, Unicode
filenames, Command-X/V server-side moves (destination present, source empty), ZIP
creation, extraction to a numbered conflict-free folder, and rename/toolbar undo were
verified live with only generated fixtures. Internal move/toolbar undo was then
verified with the moved file removed from the temporary destination. Existing user
cloud content was untouched.
The cloud-history/progress build was verified live on 2026-10-05: the generated
Unicode test file was moved from the test folder into `Quelle`, appeared there,
and was restored using online Undo. The normal History panel displayed the move
with both complete online paths, and both audit entries survived a full app restart.
The pane-local loading indicator and cancellable global transfer indicator were
observed during real Graph requests. Google Drive `Meine Ablage` and iCloud root
listings also loaded successfully; their requests completed before UI capture, so
the local spinner's in-flight appearance was not independently captured live.
The mocked OneDrive suite passes 11 groups; safety/history tests now pass 9 groups,
including mixed local/remote history persistence and local undo compatibility.
Only the generated fixtures were changed, and the cloud test file was restored.

Automated mouse drags did not produce a transfer, so live drag-and-drop remains
unverified; source-cell reload during drag initialization was removed because it can
invalidate the Catalyst lift preview. The automation's key mapping on the German
keyboard sent Preview for its first attempted Command-Z, so keyboard undo is not
claimed from that attempt. A generated SVG also exposed the common image viewer's
unsupported vector decoding. System document preview stalled for that fixture;
the viewer now requests a bounded system-generated vector thumbnail instead. The
installed correction rendered the generated SVG correctly in the regular image viewer.
The user's manual drag produced “The application did not provide a supported file
representation.” Internal local-pane drops now use the carried FileEntry URL directly;
exported providers explicitly advertise file URLs and use data for abstract/unknown
content types. The provider regression suite passes eight groups, including an
extensionless file; live verification
of this final drag correction is still pending.
The disposable cloud/local fixture folders are retained pending that manual test;
they have not been permanently deleted or mixed with existing user content.
An initial paste with stale pane focus attempted a same-folder copy and was refused
with HTTP 409 (no existing destination overwritten). Local path editing/background
clicks now activate their pane; destination conflicts remain hard failures.

## Reproducible non-account test

```sh
sh tests/run-onedrive-tests.sh
```

No account, password, keychain change or live cloud write is used by this test.

## Microsoft reference

- [App registration](https://learn.microsoft.com/en-us/entra/identity-platform/quickstart-register-app)
- [Device authorization flow](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-device-code)
- [List files](https://learn.microsoft.com/en-us/graph/api/driveitem-list-children?view=graph-rest-1.0)
- [Small-file upload](https://learn.microsoft.com/en-us/graph/api/driveitem-put-content?view=graph-rest-1.0)
- [Upload sessions](https://learn.microsoft.com/en-us/graph/api/driveitem-createuploadsession?view=graph-rest-1.0)
- [Server-side moves](https://learn.microsoft.com/en-us/graph/api/driveitem-move?view=graph-rest-1.0)
- [Conflict and download attributes](https://learn.microsoft.com/en-us/graph/api/resources/driveitem?view=graph-rest-1.0#instance-attributes)
