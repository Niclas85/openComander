#!/bin/sh
set -eu
if [ "${EFFECTIVE_PLATFORM_NAME:-}" != "-maccatalyst" ]; then exit 0; fi
task_output="$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH/OpenCommanderSSHAskPass"
mkdir -p "$(dirname "$task_output")"
task_sdk=$(xcrun --sdk macosx --show-sdk-path)
task_archs=${ARCHS:-arm64}
task_temp=$(mktemp -d -t opencommander-askpass)
trap 'rm -rf "$task_temp"' EXIT HUP INT TERM
for task_arch in $task_archs; do
    case "$task_arch" in arm64|x86_64) ;; *) exit 1 ;; esac
    xcrun --sdk macosx clang -Os -Wall -Wextra -Werror -isysroot "$task_sdk" \
        -target "$task_arch-apple-macos13" "$SRCROOT/OpenCommanderMacBridge/SSHAskPass.c" -o "$task_temp/$task_arch"
done
xcrun lipo -create "$task_temp"/* -output "$task_output"
if [ "${CODE_SIGNING_ALLOWED:-NO}" = "YES" ]; then
    /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --options runtime "$task_output"
fi
