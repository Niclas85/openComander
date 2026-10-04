#!/bin/sh
set -eu
task_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
task_output=$(mktemp -d -t opencommander-onedrive-tests)
trap 'rm -f "$task_output/onedrive-tests"; rmdir "$task_output"' EXIT HUP INT TERM
xcrun swiftc -parse-as-library \
    "$task_root/ios/OpenCommander/OneDriveClient.swift" \
    "$task_root/ios/tests/OneDriveTests/OneDriveTests.swift" \
    -o "$task_output/onedrive-tests"
"$task_output/onedrive-tests"
