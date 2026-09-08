#!/bin/sh
set -eu
task_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
sh "$task_root/build-engine.sh"
task_source="$task_root/.build-native/ntfs-3g-2026.7.7"
clang -Wall -Wextra -Werror -g -mmacosx-version-min=15.4 -DHAVE_CONFIG_H -DNK_TESTING \
    -I"$task_source" -I"$task_source/include" -I"$task_source/include/ntfs-3g" \
    -I"$task_root/bridge" "$task_root/bridge/ntfs_bridge.c" \
    "$task_root/tests/image_tests.c" "$task_source/libntfs-3g/.libs/libntfs-3g.a" \
    -framework CoreFoundation -o "$task_root/.build-native/image-tests"
task_fixture=$(mktemp -d "$task_root/.build-native/test-images.XXXXXX")
"$task_root/.build-native/image-tests" "$task_fixture/test.ntfs" "$task_source/ntfsprogs/mkntfs" "$@"
