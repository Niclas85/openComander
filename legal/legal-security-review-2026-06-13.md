# Legal and Security Review

Date: 13 June 2026

## Summary

OpenCommander is legally and technically plausible for publication as a free, open-source Android file manager, but final release still requires real provider/contact data and a public privacy policy URL.

## Legal Check

### Good

- App positioning says free and open source.
- App does not claim cloud, backup or server sync features.
- Privacy texts match the current implementation: no account, no ads, no tracking, no analytics SDKs and no provider server upload.
- Terms mention local file operations, user responsibility and limitation of liability.
- Impressum template exists.
- Play listing drafts avoid using third-party product names as the main marketing claim.

### Must Complete Before Publication

- Contact email is set to `info@opengames.vip`; real provider name and postal address still need to be filled in.
- Publish privacy policy and imprint on a public URL.
- Choose and confirm the open-source license. Current project default is MIT.
- Source repository is public: https://github.com/Niclas85/openComander
- Complete Google Play Data Safety based on the actual final build.
- Complete Google Play All Files Access declaration.
- Use `playstore/data-safety-de.md` and `playstore/all-files-access-de.md` as the prepared Play Console answers.
- Use `legal/privacy-policy-public-template-de.md` as the public privacy policy draft and replace all bracketed provider placeholders.

### Recommended Data Safety Answers

For the current build:

- Data collected by app: none, assuming no crash reporting, analytics, ads or account system are added.
- Data shared by app: none by the provider.
- Files: accessed locally only for user-triggered file manager actions.
- Account deletion: not applicable because there is no account.
- Data encryption in transit: not applicable for app data because no app network transfer is used.

If future features add cloud, SFTP, crash reports, telemetry or ads, these answers must change.

## Google Play Policy Check

### All Files Access

The app requests `MANAGE_EXTERNAL_STORAGE`. This is high-scrutiny but appropriate to justify because the core app purpose is file management across shared storage.

Suggested declaration:

> OpenCommander is a local file manager. All files access is required so users can browse folders, copy files, move files, create ZIP archives, open ZIP archives and undo file operations across shared storage locations chosen by the user. The app does not upload files to provider servers and does not use ads or analytics.

### Target API

The project targets SDK 35, which matches current Google Play requirements for new Android app submissions and updates.

## Security Check

### Good

- `targetSdk` and `compileSdk` are 35.
- No runtime dependencies are present in `releaseRuntimeClasspath`.
- No internet permission is declared.
- No cleartext traffic is allowed.
- App data backup is disabled.
- Provider is not exported.
- Provider supports read-only file opening.
- Activity export is limited to launcher behavior.

### Improvements Applied

- Removed unnecessary `READ_MEDIA_IMAGES`, `READ_MEDIA_VIDEO` and `READ_MEDIA_AUDIO` permissions.
- Set `android:allowBackup="false"`.
- Set `android:fullBackupContent="false"`.
- Set `android:usesCleartextTraffic="false"`.

### Remaining Technical Risks

- Broad file access is inherently sensitive. UI copy and Play declaration must be transparent.
- Undo history is local and helpful, but partial failures should be tested carefully.
- ZIP handling should be tested with malformed, huge and deeply nested ZIP archives.
- File operations should be tested on internal storage, SD cards and Android version differences.
- Opening files with third-party apps grants those apps read access to the selected file URI.

## Release Gate

Do not publish until:

- privacy policy URL is live
- imprint/provider details are live
- open-source repository is public: https://github.com/Niclas85/openComander
- release signing is configured
- AAB release build is generated and tested
- Play declarations are filled from this review

Prepared files now exist for the Play declarations and public privacy policy draft. The only remaining parts that cannot be completed locally are real provider data, public legal URLs and production signing credentials.
