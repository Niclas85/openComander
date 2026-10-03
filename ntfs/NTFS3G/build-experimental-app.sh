#!/bin/sh
# Explicit developer build only. Does not install, approve or mount anything.
set -eu
task_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
test "$#" -eq 0 || { echo "Usage: sh build-experimental-app.sh" >&2; exit 1; }
task_build="$task_root/ntfs/NTFS3G/.build-native/experimental-app"
xcrun xcodebuild -project "$task_root/ios/OpenCommander.xcodeproj" \
    -scheme OpenCommander -configuration Debug \
    -destination 'platform=macOS,variant=Mac Catalyst,arch=arm64' \
    -derivedDataPath "$task_build" ONLY_ACTIVE_ARCH=YES \
    OPENCOMMANDER_NTFS_WRITE_CONDITION=OPENCOMMANDER_NTFS3G_EXPERIMENTAL build
task_app="$task_build/Build/Products/Debug-maccatalyst/OpenCommander.app"
task_mode=$(/usr/libexec/PlistBuddy -c 'Print :OpenCommanderNTFSWriteCondition' \
    "$task_app/Contents/Extensions/OpenCommanderNTFSModule.appex/Contents/Info.plist")
test "$task_mode" = OPENCOMMANDER_NTFS3G_EXPERIMENTAL
codesign --verify --deep --strict "$task_app"
echo "EXPERIMENTAL_APP $task_app"
echo "Not production-ready. Install explicitly, then run test-fskit.sh as the login user."
