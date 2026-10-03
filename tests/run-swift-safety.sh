#!/bin/sh
set -eu
task_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
task_output=$(mktemp -d)
trap 'rm -rf "$task_output"' EXIT HUP INT TERM
swiftc "$task_root/ios/OpenCommander/Localization.swift" \
    "$task_root/ios/OpenCommander/FileOperationSafety.swift" \
    "$task_root/ios/tests/FileOperationSafetyTests/main.swift" -o "$task_output/safety-tests"
"$task_output/safety-tests"
