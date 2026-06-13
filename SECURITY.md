# Security Policy

## Scope

OpenCommander is a local Android file manager. Security-sensitive areas are:

- file access permissions
- copy, move, delete and undo operations
- ZIP archive reading and creation
- temporary cache files for undo/opening ZIP entries
- content URI sharing when files are opened with other apps

## Current Security Posture

- No network permission is declared.
- No analytics, ads or third-party SDK dependencies are used.
- The app does not define exported services, receivers or providers.
- The file content provider is `exported=false` and grants read access only for app-created content URIs.
- The app disables Android backup for app data.
- Cleartext network traffic is explicitly disabled.

## Reporting Issues

Please report security issues privately to the project maintainer before posting public details.

Include:

- Android version and device model
- app version/build
- reproduction steps
- whether the issue involves local files, ZIP files, undo history or another app

## Security Principles

OpenCommander should remain:

- local-first
- without tracking
- without ads
- without account requirements
- minimal in permissions for a full file manager
- transparent about destructive file operations

## Known Review Items Before Release

- Confirm that `MANAGE_EXTERNAL_STORAGE` is accepted for the file manager use case in the target store.
- Test undo behavior for partial copy/move failures.
- Test ZIP handling with malformed and very large archives.
- Ensure screenshots and public issue reports do not expose private file names.
