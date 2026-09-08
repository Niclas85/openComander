#!/bin/sh
# Run in the login user's context: FSKit approvals are per-user, not root's.
# Only a newly created 64 MiB disk image is ever mounted, never a user disk.
set -eu
test "$(id -u)" != 0 || { echo "Run as your normal user, not with sudo." >&2; exit 1; }
task_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
case "${1:-}" in
    ""|--check-only) ;;
    *) echo "Usage: sh test-fskit.sh [--check-only]" >&2; exit 1 ;;
esac
test "$#" -le 1 || { echo "Too many arguments." >&2; exit 1; }
# Discovery is advisory where FSClient omits a pluginkit-registered module.
xcrun swift "$task_root/tests/fskit_preflight.swift"
test "${1:-}" != --check-only || exit 0
task_available_kib=$(df -Pk "$task_root" | awk 'END { print $4 }')
case "$task_available_kib" in
    ''|*[!0-9]*) echo "Cannot determine free disk space; stopping." >&2; exit 1 ;;
esac
test "$task_available_kib" -ge 524288 || {
    echo "At least 512 MiB free space is required for this test; available: $task_available_kib KiB. No image created." >&2
    exit 1
}
sh "$task_root/build-engine.sh"
test -x "$task_root/.build-native/image-tests" || { echo "First run sh test-engine.sh" >&2; exit 1; }
task_fixture=$(mktemp -d "$task_root/.build-native/fskit-fixture.XXXXXX")
task_image="$task_fixture/test.ntfs"
"$task_root/.build-native/image-tests" "$task_image" "$task_root/.build-native/ntfs-3g-2026.7.7/ntfsprogs/mkntfs" --clean
# fskitd cannot mount inside TCC-protected Documents on macOS 15.6. Use a
# private, user-owned temporary mountpoint, without changing any TCC settings.
task_mount_fixture=$(mktemp -d /private/tmp/fskit-fixture.XXXXXX)
task_mount="$task_mount_fixture/mount"
mkdir "$task_mount"
task_disk=$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage -plist "$task_image" |
    plutil -extract system-entities.0.dev-entry raw -o - -)
case "$task_disk" in /dev/disk[0-9]*) ;; *) echo "Unexpected image device: $task_disk" >&2; exit 1;; esac
task_cleanup() {
    task_status=$?
    if test -n "$task_disk" && ! hdiutil detach "$task_disk"; then
        echo "Could not detach test image $task_image; inspect before retrying." >&2
        exit 1
    fi
    exit "$task_status"
}
trap task_cleanup EXIT
task_virtual=$(diskutil info -plist "$task_disk" | plutil -extract VirtualOrPhysical raw -o - -)
task_protocol=$(diskutil info -plist "$task_disk" | plutil -extract BusProtocol raw -o - -)
task_size=$(diskutil info -plist "$task_disk" | plutil -extract TotalSize raw -o - -)
test "$task_virtual" = Virtual && test "$task_protocol" = "Disk Image" && test "$task_size" = 67108864
echo "Mounting only the NEW test image $task_image ($task_disk) in the login user's FSKit context."
if /sbin/mount -F -t openntfs -o nosuid,nodev,noowners "$task_disk" "$task_mount"; then
    :
else
    task_mount_status=$?
    echo "FSKit mount failed (exit $task_mount_status). No mounted write tests ran." >&2
    echo "Do not retry with sudo: root has a separate extension registry/approval context." >&2
    echo "For Operation not permitted, inspect the system log for file-mount denial at $task_mount." >&2
    echo "Fixture retained for diagnosis: $task_image" >&2
    exit "$task_mount_status"
fi
xcrun swift "$task_root/tests/mounted_tests.swift" "$task_mount"
# Verify persisted bytes using a different NTFS implementation after teardown.
hdiutil detach "$task_disk"
task_disk=""
task_disk=$(hdiutil attach -readonly -nobrowse -mountpoint "$task_mount" \
    -imagekey diskimage-class=CRawDiskImage -plist "$task_image" |
    plutil -extract system-entities.0.dev-entry raw -o - -)
case "$task_disk" in /dev/disk[0-9]*) ;; *) echo "Unexpected reopened image device: $task_disk" >&2; exit 1;; esac
xcrun swift "$task_root/tests/verify_reopened.swift" "$task_mount"
