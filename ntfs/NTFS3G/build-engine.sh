#!/bin/sh
# Build only the NTFS engine and image tools: no FUSE, installer, or mount helper.
set -eu
task_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
task_archive="$task_root/vendor/ntfs-3g_ntfsprogs-2026.7.7.tgz"
task_hash=d67b769025d32860549d35c2147e45024d172f81c540d750390ce3602c059dab
test "$(shasum -a 256 "$task_archive" | cut -d ' ' -f 1)" = "$task_hash"
mkdir -p "$task_root/.build-native"
if [ ! -d "$task_root/.build-native/ntfs-3g-2026.7.7" ]; then
    tar -xzf "$task_archive" -C "$task_root/.build-native"
fi
cd "$task_root/.build-native/ntfs-3g-2026.7.7"
if [ ! -f Makefile ]; then
    ./configure --disable-ntfs-3g --disable-shared --enable-static \
        --disable-crypto --disable-extras --disable-plugins \
        CFLAGS="-O2 -g -mmacosx-version-min=15.4"
fi
make -j4
