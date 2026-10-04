# OneDrive online (macOS, experimental)

OpenCommander now has a separate native online browser under **Settings → OneDrive online**.
The OneDrive recovery button also opens this screen. It uses Microsoft Graph, not the
local File Provider folder, and does not depend on the OneDrive sync application.

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
- Uploads a selected local file up to **20 MB**, refusing name collisions rather than replacing.
- Creates folders, renames entries and moves selected entries to the OneDrive recycle bin
  after explicit confirmation.
- Stores renewable credentials in macOS Keychain, not preferences or logs. Disconnect
  removes the saved credential for the currently configured app ID without deleting files.
- No integration of remote entries into the two local panes yet; no remote drag/drop,
  directory upload/download, large-file upload sessions, shared-library discovery or multi-account UI.
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
No further login prompt was required after relaunch. Cloud write operations have only
been tested against mocked Microsoft responses; no user cloud files were changed.

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
- [Conflict and download attributes](https://learn.microsoft.com/en-us/graph/api/resources/driveitem?view=graph-rest-1.0#instance-attributes)
