# NTFS-3G / FSKit prototype — NOT production-ready

The previous independent MIT engine remains separate. This GPL-2.0-or-later
integration builds NTFS-3G 2026.7.7 without FUSE and uses callback I/O so the
same engine facade can operate on a regular test image or an FSKit resource.
See [THIRD-PARTY.md](THIRD-PARTY.md) for provenance and source delivery.

## Build / tests

Requires Xcode tools, make and pkg-config (`brew install pkgconf` on this Mac).

```sh
sh ntfs/NTFS3G/build-engine.sh
sh ntfs/NTFS3G/test-engine.sh
swift test --package-path ntfs/OpenCommanderNTFS
```

The build does not install drivers, FUSE or command-line tools system-wide.
Generated files stay in `.build-native`. The image tests exclusively CREATE
a new regular file, format that file, and keep it for independent inspection.
They do not accept an existing disk as a write target. Native architecture only;
universal/Intel release packaging has not been verified.

To build the opt-in macOS prototype after building the engine:

```sh
xcodebuild -project ios/OpenCommander.xcodeproj -scheme OpenCommanderNTFSModule \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG OPENCOMMANDER_NTFS3G_EXPERIMENTAL' \
  ONLY_ACTIVE_ARCH=YES build
```

The scheme also builds its containing Catalyst app. No automatic claim of
NTFS devices is configured (`FSMediaTypes` is empty). The ordinary build still
refuses mounts. Do not turn the experimental build into the default release.

## Observed results (8 September 2026)

- Native image tests pass: small and nonresident writes, resize/zero fill,
  Unicode, case collisions, directory rename, create/delete, directory index
  growth to 200 entries, replace, case-only rename, restore after injected
  replacement failure, real ENOSPC, device-write and flush error reporting,
  persistence after reopen, read-only protection, hibernation rejection.
- macOS's own read-only NTFS implementation independently mounted the result
  and read the expected 13-byte `HELLO.TXT`, 8192-byte `large.bin`, and 200
  directory entries. That test image was then detached.
- Signed macOS app and embedded FSKit module build successfully (Apple Silicon).
- FSKit mount and VFS write tests now PASS on macOS 15.6, without sudo:
  Unicode, create/read/write (including a 2 MiB file), copy, rename, atomic
  replacement via Foundation, delete, truncate and fsync.
- After clean detach, Apple's separate read-only NTFS driver read back the
  exact Unicode payload and 517-byte truncated file and confirmed deletions.
- Earlier failures: an initial missing `.ready` container transition was
  fixed. The remaining `Operation not permitted` was diagnosed in the kernel
  log as `System Policy: fskitd ... deny(1) file-mount` at the Documents path.
  Moving only the test mountpoint to a private `/private/tmp/fskit-fixture.*`
  directory resolved it. No TCC permissions or SIP settings were changed.
- The user subsequently authorized two `sudo mount` attempts. Both failed
  earlier with `mount: Unable to invoke task`; logs show module discovery but
  no launch of our extension. Administrator authorization was NOT the fix.
- Read-only diagnosis: pluginkit lists the signed extension, and the login
  user's FSKit enabledModules preferences contain its bundle identifier, but
  `FSClient.shared.fetchInstalledExtensions` from both interpreted and compiled
  command-line checks returns only Apple's exFAT/MS-DOS modules. Actual mount
  nevertheless starts and activates our extension. The old preflight's hard
  failure was a false negative; missing API entries now fall back to read-only
  pluginkit registration lookup and a warning, not an assertion of approval.
- OpenCommander UI tests and production safety gates are still NOT passed.

Full corrected `sh ntfs/NTFS3G/test-fskit.sh` run: exit 0, fixture
`.build-native/fskit-fixture.Tj5klb/test.ntfs`, test directory
`OpenCommander-Test-6BFC5EAA-B9EF-451F-A9B4-FED258166BDB`.
Both FSKit and Apple read-only mounts were detached normally. No physical
disk was written or remounted. The successful script output ends with:

```text
PASS FSKit mount: Unicode, create, read/write, copy, rename, replace, delete, truncate, fsync
"disk7" ejected.
PASS independent Apple NTFS read-only reopen: exact Unicode content, 517-byte data, rename/delete persistence
"disk7" ejected.
```

## Next integration test

First run the read-only preflight as the normal login user:

```sh
sh ntfs/NTFS3G/test-fskit.sh --check-only
```

If neither discovery method finds the module, launch the built experimental
containing app and check its File System Extension in System Settings → General
→ Login Items & Extensions. Do not interpret the FSClient omission warning as
a request to re-enable an already working extension. Do not edit preferences manually,
disable SIP, or restart system FSKit services while user disks are attached.

Only once preflight succeeds and at least 512 MiB is free, run:

```sh
sh ntfs/NTFS3G/test-fskit.sh
```

This prepares a fresh image, verifies that its device is a virtual 64 MiB disk
image, and mounts in the login user's context, without sudo. FSKit extension
registration/consent is per-user; root does not inherit that state. Apple
confirms this in [AppEx lifecycle improvements](https://developer.apple.com/forums/thread/831396).
The mountpoint is a newly created private temporary directory, outside protected
Documents. `tests/mounted_tests.swift` exercises VFS file operations. It checks
the reported type `openntfs` (not `fskit`) and the canonical mount root before
writing. `tests/verify_reopened.swift` checks persistence after detach and
read-only remount with Apple's `ntfs` driver. OpenCommander UI tests remain a
separate gate; success of the script alone is not full release approval.

Preflight now exits 0 with an explicit warning when the module is registered
but omitted by FSClient. It does not call that a passed mount/write test.
Shell syntax and Swift runtime checks pass. Initially only about 195 MiB was
free; later 1.2 GiB was available. The test refuses new fixtures below 512 MiB. Existing fixtures are
retained, never silently deleted. The mkntfs warning about Windows being unable
to boot from a raw image is expected: these are data-volume fixtures, not
Windows boot disks.

## Remaining safety / functionality gates

- Crash/power-loss consistency and interrupted metadata writes are NOT proven.
  Recovery-name replacement protects the previous target in tested ordinary
  failure paths; it is not a crash-atomic NTFS transaction or journal replay.
- Dirty volumes and Windows hibernation are rejected for writing. No forced
  recovery, journal reset, formatting of user disks, or security-policy changes.
- Symlink/hardlink creation, NTFS ACL mapping, timestamp-setting and extended
  attributes are not complete in the FSKit prototype. Compressed/encrypted
  file writes and writes to NTFS system files are refused.
- Mount/unmount lifecycle, concurrency, open-unlink, very large files and
  rollback failures still need comprehensive integration testing.
- The user's `Elements` disk has not been written, remounted, or reformatted.

### Cleanup of the failed system mount

The denied mount initially left two test extension processes holding the
64 MiB image. Both processes were verified as belonging to this test and
terminated; the image then detached normally. No system-wide FSKit daemon
was restarted, and no physical disk was detached. A `deinit` cleanup for the
engine handle was added to cover failed-mount teardown as well.

Three obsolete generated image files were removed to reclaim approximately
131 MiB; they are reproducible with the test script. The latest successful
native fixture is retained in `.build-native/test-images.9x6e9V/test.ntfs`.
