#!/bin/sh
set -eu
task_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
task_output=$(mktemp -d)
trap 'rm -rf "$task_output"' EXIT HUP INT TERM
javac -d "$task_output" \
    "$task_root/app/src/main/java/com/opencommander/FileOperationSafety.java" \
    "$task_root/tests/java/com/opencommander/FileOperationSafetyTest.java"
java -cp "$task_output" com.opencommander.FileOperationSafetyTest
