/* SPDX-License-Identifier: GPL-2.0-or-later */
/* This executable only creates a NEW regular image with O_EXCL. No device nodes. */
#include "ntfs_bridge.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL line %d: %s (errno=%d %s)\n", __LINE__, #x, errno, strerror(errno)); exit(1); } } while (0)
struct image { int fd; unsigned writes, flushes; int fail_flush, fail_writes; };
extern int nk_test_fail_move_after_backup;
static long long image_read(void *ctx, void *buf, long long count, long long offset) {
    return pread(((struct image *)ctx)->fd, buf, (size_t)count, offset);
}
static long long image_write(void *ctx, const void *buf, long long count, long long offset) {
    struct image *im = ctx; im->writes++;
    if (im->fail_writes) { errno = EIO; return -1; }
    return pwrite(im->fd, buf, (size_t)count, offset);
}
static int image_sync(void *ctx) {
    struct image *im = ctx; im->flushes++;
    if (im->fail_flush) { errno = EIO; return -1; }
    return fsync(im->fd);
}
static int count_entry(void *ctx, const nk_dirent *entry) {
    CHECK(entry->name && *entry->name);
    (*(unsigned *)ctx)++;
    return 0;
}
static nk_volume *mount_image(nk_io *io) {
    char error[512] = {0};
    nk_volume *v = nk_mount_io(io, error, sizeof(error));
    if (!v) fprintf(stderr, "%s\n", error);
    CHECK(v);
    return v;
}
static void verify(nk_volume *v, const char *path, const void *expected, size_t length) {
    char *readback = malloc(length ? length : 1);
    CHECK(readback);
    CHECK(nk_read(v, path, 0, length, readback) == (long long)length);
    CHECK(!memcmp(readback, expected, length));
    free(readback);
}

int main(int argc, char **argv) {
    CHECK(argc == 3 || (argc == 4 && !strcmp(argv[3], "--clean"))); /* new image path, mkntfs executable */
    struct image im = { .fd = open(argv[1], O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0600) };
    CHECK(im.fd >= 0);
    struct stat st;
    CHECK(!fstat(im.fd, &st) && S_ISREG(st.st_mode) && st.st_nlink == 1);
    const long long capacity = 64LL * 1024 * 1024;
    CHECK(!ftruncate(im.fd, capacity));
    pid_t child = fork();
    CHECK(child >= 0);
    if (!child) {
        execl(argv[2], argv[2], "-F", "-Q", "-L", "OC-NTFS-TEST", argv[1], (char *)NULL);
        _exit(127);
    }
    int status = 0;
    CHECK(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0);
    nk_io io = { .ctx = &im, .pread = image_read, .pwrite = image_write,
                 .sync = image_sync, .size = capacity, .readonly = 0 };
    nk_volume *v = mount_image(&io);
    CHECK(!nk_create(v, "/", "hello.txt"));
    CHECK(nk_write(v, "/hello.txt", 0, 13, "Hello NTFS!\r\n") == 13);
    verify(v, "/hello.txt", "Hello NTFS!\r\n", 13);
    puts("PASS create, write, read small file");

    CHECK(!nk_mkdir(v, "/", "Grüsse-文件"));
    CHECK(!nk_create(v, "/Grüsse-文件", "données.txt"));
    CHECK(nk_write(v, "/Grüsse-文件/données.txt", 0, 7, "Unicode") == 7);
    verify(v, "/Grüsse-文件/données.txt", "Unicode", 7);
    CHECK(nk_create(v, "/", "HELLO.TXT") == -1 && errno == EEXIST);
    CHECK(nk_create(v, "/", "../escape") == -1);
    CHECK(nk_create(v, "/", "bad:name") == -1);
    puts("PASS Unicode, case-insensitive collision, invalid names");

    const size_t large_size = 2 * 1024 * 1024 + 37;
    unsigned char *large = malloc(large_size);
    CHECK(large);
    for (size_t i = 0; i < large_size; i++) large[i] = (unsigned char)(i * 17);
    CHECK(!nk_create(v, "/", "large.bin"));
    CHECK(nk_write(v, "/large.bin", 0, large_size, large) == (long long)large_size);
    verify(v, "/large.bin", large, large_size);
    CHECK(!nk_truncate(v, "/large.bin", 500));
    CHECK(!nk_truncate(v, "/large.bin", 8192));
    unsigned char extended[8192] = {0};
    memcpy(extended, large, 500);
    verify(v, "/large.bin", extended, sizeof(extended));
    puts("PASS nonresident data, shrink, grow with zero-filled extension");

    CHECK(!nk_rename(v, "/Grüsse-文件", "/", "Moved"));
    verify(v, "/Moved/données.txt", "Unicode", 7);
    CHECK(nk_delete(v, "/Moved") == -1 && errno == ENOTEMPTY);
    CHECK(nk_rename(v, "/Moved", "/Moved", "cycle") == -1);
    CHECK(nk_rename(v, "/hello.txt", "/", "large.bin") == -1 && errno == EEXIST);
    verify(v, "/hello.txt", "Hello NTFS!\r\n", 13);
    verify(v, "/large.bin", extended, sizeof(extended));
    CHECK(!nk_create(v, "/", "delete-me"));
    CHECK(!nk_delete(v, "/delete-me"));
    puts("PASS directory rename, delete, nonempty/cycle/collision protection");

    CHECK(!nk_create(v, "/", "replacement.txt"));
    CHECK(nk_write(v, "/replacement.txt", 0, 3, "new") == 3);
    char recovery[4096];
    nk_test_fail_move_after_backup = 1;
    CHECK(nk_move(v, "/replacement.txt", "/", "hello.txt", 1, recovery, sizeof(recovery)) == -1);
    CHECK(errno == ENOSPC && !recovery[0]);
    verify(v, "/hello.txt", "Hello NTFS!\r\n", 13);
    verify(v, "/replacement.txt", "new", 3);
    puts("PASS failed replacement restores old destination and preserves source");
    CHECK(!nk_move(v, "/replacement.txt", "/", "hello.txt", 1, recovery, sizeof(recovery)));
    verify(v, "/hello.txt", "new", 3);
    CHECK(!nk_move(v, "/hello.txt", "/", "HELLO.TXT", 0, recovery, sizeof(recovery)));
    verify(v, "/HELLO.TXT", "new", 3);
    CHECK(nk_write(v, "/HELLO.TXT", 0, 13, "Hello NTFS!\r\n") == 13);
    puts("PASS replace existing file and case-only rename");

    CHECK(!nk_create(v, "/", "fill.bin"));
    long long filled = 0;
    int reached_full = 0;
    while (filled < capacity * 2) {
        long long written = nk_write(v, "/fill.bin", filled, large_size, large);
        if (written != (long long)large_size) { reached_full = 1; break; }
        filled += written;
    }
    CHECK(reached_full);
    verify(v, "/HELLO.TXT", "Hello NTFS!\r\n", 13);
    CHECK(!nk_delete(v, "/fill.bin"));
    CHECK(!nk_create(v, "/", "after-full.txt"));
    CHECK(nk_write(v, "/after-full.txt", 0, 2, "OK") == 2);
    puts("PASS disk full, existing content intact, free space reusable");

    im.fail_flush = 1;
    CHECK(nk_sync(v) == -1);
    im.fail_flush = 0;
    CHECK(!nk_sync(v));
    puts("PASS flush failure is reported, subsequent flush succeeds");

    // A failed block write must not become a positive byte count in the facade.
    im.fail_writes = 1;
    CHECK(nk_write(v, "/HELLO.TXT", 0, 13, "XXXXXXXXXXXXX") == -1);
    im.fail_writes = 0;
    // An I/O failure is not an atomic-write promise: explicitly restore fixture.
    CHECK(nk_write(v, "/HELLO.TXT", 0, 13, "Hello NTFS!\r\n") == 13);
    puts("PASS device write failure propagates to caller");

    // Force an index root to grow into allocation-backed directory index blocks.
    CHECK(!nk_mkdir(v, "/", "many"));
    for (int i = 0; i < 200; i++) {
        char name[32]; snprintf(name, sizeof(name), "entry-%03d.txt", i);
        CHECK(!nk_create(v, "/many", name));
    }
    unsigned count = 0;
    CHECK(!nk_list(v, "/many", count_entry, &count) && count == 200);
    CHECK(!nk_sync(v) && im.flushes > 0);
    CHECK(!nk_umount(v));
    puts("PASS directory index growth (200 files), flush and close");

    io.readonly = 1;
    unsigned before = im.writes;
    v = mount_image(&io);
    verify(v, "/hello.txt", "Hello NTFS!\r\n", 13);
    verify(v, "/Moved/données.txt", "Unicode", 7);
    verify(v, "/large.bin", extended, sizeof(extended));
    count = 0;
    CHECK(!nk_list(v, "/many", count_entry, &count) && count == 200);
    CHECK(nk_write(v, "/hello.txt", 0, 1, "X") == -1 && errno == EROFS);
    CHECK(nk_create(v, "/", "forbidden") == -1 && errno == EROFS);
    CHECK(nk_delete(v, "/hello.txt") == -1 && errno == EROFS);
    CHECK(!nk_umount(v));
    CHECK(before == im.writes);
    puts("PASS persistence after reopen, readonly causes zero writes");

    io.readonly = 0;
    v = mount_image(&io);
    if (argc == 4) {
        CHECK(!nk_umount(v));
        CHECK(!close(im.fd));
        free(large);
        printf("CLEAN_IMAGE %s\n", argv[1]);
        return 0;
    }
    CHECK(!nk_create(v, "/", "hiberfil.sys"));
    unsigned char hiber[4096] = {'h','i','b','r'};
    CHECK(nk_write(v, "/hiberfil.sys", 0, sizeof(hiber), hiber) == sizeof(hiber));
    CHECK(!nk_umount(v));
    before = im.writes;
    char error[512] = {0};
    CHECK(nk_mount_io(&io, error, sizeof(error)) == NULL);
    CHECK(before == im.writes);
    puts("PASS hibernation blocks write mount before any device write");
    // Keep this fixture: independent OS/Windows verification can read it.
    CHECK(!close(im.fd));
    free(large);
    printf("IMAGE %s\n", argv[1]);
    return 0;
}
