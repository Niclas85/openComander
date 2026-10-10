#!/bin/sh
set -eu
task_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
task_output=$(mktemp -d -t opencommander-remote-tests)
trap 'rm -rf "$task_output"' EXIT HUP INT TERM
cd "$task_root"
xcrun --sdk macosx clang -Os -Wall -Wextra -Werror ios/OpenCommanderMacBridge/SSHAskPass.c -o "$task_output/OpenCommanderSSHAskPass"
xcrun swiftc -parse-as-library -DREMOTE_TRANSPORT_TESTS \
    ios/OpenCommander/RemoteConnection.swift \
    ios/OpenCommander/DesktopBridgeProtocol.swift \
    ios/OpenCommanderMacBridge/DesktopBridge.swift \
    ios/OpenCommander/OneDriveClient.swift \
    ios/OpenCommander/RemoteFileClient.swift \
    ios/tests/RemoteTests/RemoteTests.swift -o "$task_output/remote-tests"
if [ "$#" -gt 0 ]; then
    "$task_output/remote-tests" "$1" "$task_output/fixture" "$task_output/OpenCommanderSSHAskPass"
else
    "$task_output/remote-tests"
fi
