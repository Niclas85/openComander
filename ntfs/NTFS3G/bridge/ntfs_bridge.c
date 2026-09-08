// Adapted for OpenCommander from whereteam/ntfskit b7153a8dd51b895d0a87345c6ad8e95bda963ed3.
// See ../THIRD-PARTY.md. Only the byte-copy engine facade is included.
/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "ntfs_bridge.h"

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>
#include <time.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <limits.h>
#ifdef NK_TESTING
int nk_test_fail_move_after_backup;
#endif

#include <ntfs-3g/types.h>
#include <ntfs-3g/layout.h>
#include <ntfs-3g/volume.h>
#include <ntfs-3g/inode.h>
#include <ntfs-3g/dir.h>
#include <ntfs-3g/attrib.h>
#include <ntfs-3g/unistr.h>
#include <ntfs-3g/ntfstime.h>
#include <ntfs-3g/device.h>
#include <ntfs-3g/reparse.h>
#include <ntfs-3g/runlist.h>

struct nk_volume {
    ntfs_volume *vol;
    void *devctx;
};

/* ---- callback-backed ntfs_device ---- */

struct nk_devctx {
    nk_io io;
    s64   pos;
};

static int nkdev_open(struct ntfs_device *dev, int flags) {
    if ((flags & O_ACCMODE) == O_RDONLY)
        NDevSetReadOnly(dev);
    NDevSetOpen(dev);
    return 0;
}

static int nkdev_close(struct ntfs_device *dev) {
    NDevClearOpen(dev);
    return 0;
}

static s64 nkdev_seek(struct ntfs_device *dev, s64 offset, int whence) {
    struct nk_devctx *c = dev->d_private;
    if (whence != SEEK_SET && whence != SEEK_CUR && whence != SEEK_END) {
        errno = EINVAL; return -1;
    }
    s64 base = whence == SEEK_SET ? 0 :
               whence == SEEK_CUR ? c->pos : c->io.size;
    if (offset < -base || offset > c->io.size - base) { errno = EINVAL; return -1; }
    c->pos = base + offset;
    return c->pos;
}

static s64 nkdev_pread(struct ntfs_device *dev, void *buf, s64 count, s64 offset) {
    struct nk_devctx *c = dev->d_private;
    if (count < 0 || offset < 0 || offset > c->io.size || count > c->io.size - offset) {
        errno = EINVAL; return -1;
    }
    if (!count) return 0;
    s64 n = c->io.pread(c->io.ctx, buf, count, offset);
    if (n < 0) { errno = EIO; return -1; }
    return n;
}

static s64 nkdev_pwrite(struct ntfs_device *dev, const void *buf, s64 count, s64 offset) {
    struct nk_devctx *c = dev->d_private;
    if (NDevReadOnly(dev) || c->io.readonly) { errno = EROFS; return -1; }
    if (count < 0 || offset < 0 || offset > c->io.size || count > c->io.size - offset) {
        errno = EINVAL; return -1;
    }
    if (!count) return 0;
    s64 n = c->io.pwrite(c->io.ctx, buf, count, offset);
    if (n < 0) { errno = EIO; return -1; }
    NDevSetDirty(dev);
    return n;
}

static s64 nkdev_read(struct ntfs_device *dev, void *buf, s64 count) {
    struct nk_devctx *c = dev->d_private;
    s64 n = nkdev_pread(dev, buf, count, c->pos);
    if (n > 0) c->pos += n;
    return n;
}

static s64 nkdev_write(struct ntfs_device *dev, const void *buf, s64 count) {
    struct nk_devctx *c = dev->d_private;
    s64 n = nkdev_pwrite(dev, buf, count, c->pos);
    if (n > 0) c->pos += n;
    return n;
}

static int nkdev_sync(struct ntfs_device *dev) {
    struct nk_devctx *c = dev->d_private;
    if (!c->io.readonly && c->io.sync(c->io.ctx)) { errno = EIO; return -1; }
    NDevClearDirty(dev);
    return 0;
}

static int nkdev_stat(struct ntfs_device *dev, struct stat *buf) {
    struct nk_devctx *c = dev->d_private;
    memset(buf, 0, sizeof(*buf));
    buf->st_mode = S_IFREG | 0600;   /* image-file semantics: no ioctls */
    buf->st_size = c->io.size;
    return 0;
}

static int nkdev_ioctl(struct ntfs_device *dev, unsigned long request, void *argp) {
    (void)dev; (void)request; (void)argp;
    errno = ENOTSUP;
    return -1;
}

static struct ntfs_device_operations nk_dev_ops = {
    .open   = nkdev_open,
    .close  = nkdev_close,
    .seek   = nkdev_seek,
    .read   = nkdev_read,
    .write  = nkdev_write,
    .pread  = nkdev_pread,
    .pwrite = nkdev_pwrite,
    .sync   = nkdev_sync,
    .stat   = nkdev_stat,
    .ioctl  = nkdev_ioctl,
};

static nk_volume *mount_once(const nk_io *io, char *errbuf, size_t errlen) {
    struct nk_devctx *c = calloc(1, sizeof(*c));
    if (!c) return NULL;
    c->io = *io;

    struct ntfs_device *dev = ntfs_device_alloc("fskit-block", 0, &nk_dev_ops, c);
    if (!dev) { free(c); return NULL; }

    // No recovery/hibernation override: never reset the Windows journal here.
    ntfs_mount_flags flags = io->readonly ? NTFS_MNT_RDONLY : NTFS_MNT_NONE;
    ntfs_volume *vol = ntfs_device_mount(dev, flags);
    if (!vol) {
        if (errbuf && errlen)
            snprintf(errbuf, errlen, "ntfs_device_mount: %s", strerror(errno));
        ntfs_device_free(dev);
        free(c);
        return NULL;
    }
    nk_volume *v = calloc(1, sizeof(*v));
    if (!v) { ntfs_umount(vol, TRUE); free(c); return NULL; }
    v->vol = vol;
    v->devctx = c;
    if (ntfs_set_ignore_case(vol)) { nk_umount(v); return NULL; }
    return v;
}

nk_volume *nk_mount_io(const nk_io *io, char *errbuf, size_t errlen) {
    if (!io || !io->pread || io->size < 512 ||
        (!io->readonly && (!io->pwrite || !io->sync))) {
        errno = EINVAL; return NULL;
    }
    if (ntfs_set_char_encoding("UTF-8")) return NULL;
    if (!io->readonly) {
        nk_io check = *io;
        check.readonly = 1;
        nk_volume *probe = mount_once(&check, errbuf, errlen);
        if (!probe) return NULL;
        int unsafe = probe->vol->major_ver != 3 || probe->vol->minor_ver != 1 ||
            (probe->vol->flags & VOLUME_IS_DIRTY) ||
            ntfs_volume_check_hiberfile(probe->vol, 0);
        int closed = nk_umount(probe);
        if (unsafe || closed) {
            if (errbuf && errlen) snprintf(errbuf, errlen, "Write refused: dirty, hibernated, unsupported, or unreadable NTFS volume");
            errno = EROFS; return NULL;
        }
    }
    return mount_once(io, errbuf, errlen);
}

static int writable(nk_volume *v) {
    if (!v) { errno = EINVAL; return 0; }
    if (NVolReadOnly(v->vol)) { errno = EROFS; return 0; }
    return 1;
}

static int valid_name(const char *name) {
    if (!name || !*name || !strcmp(name, ".") || !strcmp(name, "..") ||
        strpbrk(name, "/\\:*?\"<>|") || strlen(name) > 1020) {
        errno = EINVAL; return 0;
    }
    size_t len = strlen(name);
    if (name[len - 1] == '.' || name[len - 1] == ' ') { errno = EINVAL; return 0; }
    for (const unsigned char *p = (const unsigned char *)name; *p; p++) {
        if (*p < 32) { errno = EINVAL; return 0; }
    }
    return 1;
}

int nk_umount(nk_volume *v) {
    if (!v) { errno = EINVAL; return -1; }
    int r = ntfs_umount(v->vol, FALSE);
    free(v->devctx);
    free(v);
    return r;
}

int nk_statvfs(nk_volume *v, long long *total_bytes, long long *free_bytes,
               int *cluster_size) {
    if (!v) return -1;
    ntfs_volume *vol = v->vol;
    if (ntfs_volume_get_free_space(vol) < 0) return -1;
    if (total_bytes)  *total_bytes  = (long long)vol->nr_clusters * vol->cluster_size;
    if (free_bytes)   *free_bytes   = (long long)vol->free_clusters * vol->cluster_size;
    if (cluster_size) *cluster_size = (int)vol->cluster_size;
    return 0;
}

int nk_label(nk_volume *v, char *buf, size_t buflen) {
    if (!v || !buf || buflen == 0) return -1;
    const char *name = v->vol->vol_name;
    snprintf(buf, buflen, "%s", name ? name : "");
    return 0;
}

/* Interix-style symlink: SYSTEM file whose data starts with "IntxLNK\1"
 * (the format ntfs_create_symlink writes, same as ntfs-3g's FUSE driver). */
static int is_intx_symlink(ntfs_attr *na) {
    if (!na || na->data_size < 10 || na->data_size > 4096 + 8) return 0;
    le64 magic = 0;
    if (ntfs_attr_pread(na, 0, sizeof(magic), &magic) != sizeof(magic)) return 0;
    return magic == INTX_SYMBOLIC_LINK;
}

static void fill_stat(ntfs_inode *ni, ntfs_attr *na, nk_stat *st) {
    memset(st, 0, sizeof(*st));
    st->is_dir = (ni->mrec->flags & MFT_RECORD_IS_DIRECTORY) ? 1 : 0;
    st->inode = (uint64_t)ni->mft_no;
    st->is_symlink = (ni->flags & FILE_ATTR_REPARSE_POINT) ? 1 : 0;
    if (!st->is_symlink && (ni->flags & FILE_ATTR_SYSTEM) && is_intx_symlink(na))
        st->is_symlink = 1;
    if (na) {
        st->size = (long long)na->data_size;
        st->alloc_size = (long long)na->allocated_size;
        st->is_resident = NAttrNonResident(na) ? 0 : 1;
        /* Compressed/encrypted data can't be mapped for the kernel — those go
         * through the byte-copy path. Resident files convert to non-resident
         * in nk_blockmap; sparse holes pack as zero-fill extents. */
        st->koio_ok = !(na->data_flags & (ATTR_IS_COMPRESSED | ATTR_IS_ENCRYPTED)) &&
                      !st->is_symlink;
    }
    st->atime = ntfs2timespec(ni->last_access_time).tv_sec;
    st->mtime = ntfs2timespec(ni->last_data_change_time).tv_sec;
    st->ctime = ntfs2timespec(ni->last_mft_change_time).tv_sec;
    st->btime = ntfs2timespec(ni->creation_time).tv_sec;
}

int nk_stat_path(nk_volume *v, const char *path, nk_stat *st) {
    if (!v || !st) return -1;
    ntfs_inode *ni = ntfs_pathname_to_inode(v->vol, NULL, path);
    if (!ni) return -1;
    ntfs_attr *na = NULL;
    if (!(ni->mrec->flags & MFT_RECORD_IS_DIRECTORY))
        na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
    fill_stat(ni, na, st);
    if (na) ntfs_attr_close(na);
    ntfs_inode_close(ni);
    return 0;
}

struct list_ctx {
    nk_volume   *v;
    nk_dirent_cb cb;
    void        *ctx;
    int          stop;
};

static int nk_filldir(void *ctx, const ntfschar *name, const int name_len,
                      const int name_type, const s64 pos, const MFT_REF mref,
                      const unsigned dt_type) {
    (void)pos;
    struct list_ctx *lc = ctx;
    if (lc->stop) return 0;
    if (name_type == FILE_NAME_DOS) return 0;          /* skip 8.3 aliases */
    if (MREF(mref) < (u64)FILE_first_user) return 0;   /* skip $MFT & friends */

    char *utf8 = NULL;
    if (ntfs_ucstombs(name, name_len, &utf8, 0) < 0 || !utf8) return 0;

    int is_dot = utf8[0] == '.' &&
                 (utf8[1] == '\0' || (utf8[1] == '.' && utf8[2] == '\0'));
    if (!is_dot) {
        nk_dirent e = { .name = utf8, .is_dir = dt_type == NTFS_DT_DIR,
                        .size = 0, .inode = MREF(mref) };
        if (!e.is_dir) {
            ntfs_inode *ni = ntfs_inode_open(lc->v->vol, mref);
            if (ni) {
                ntfs_attr *na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
                if (na) { e.size = (long long)na->data_size; ntfs_attr_close(na); }
                ntfs_inode_close(ni);
            }
        }
        if (lc->cb(lc->ctx, &e) != 0) lc->stop = 1;
    }
    free(utf8);
    return 0;
}

int nk_list(nk_volume *v, const char *dir_path, nk_dirent_cb cb, void *ctx) {
    if (!v || !cb) return -1;
    ntfs_inode *dir = ntfs_pathname_to_inode(v->vol, NULL, dir_path);
    if (!dir) return -1;
    struct list_ctx lc = { v, cb, ctx, 0 };
    s64 pos = 0;
    int r = ntfs_readdir(dir, &pos, &lc, nk_filldir);
    ntfs_inode_close(dir);
    return r ? -1 : 0;
}

long long nk_read(nk_volume *v, const char *path, long long offset,
                  long long count, void *buf) {
    if (!v) return -1;
    ntfs_inode *ni = ntfs_pathname_to_inode(v->vol, NULL, path);
    if (!ni) return -1;
    long long n = -1;
    ntfs_attr *na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
    if (na) {
        n = (long long)ntfs_attr_pread(na, offset, count, buf);
        ntfs_attr_close(na);
    }
    ntfs_inode_close(ni);
    return n;
}

long long nk_write(nk_volume *v, const char *path, long long offset,
                   long long count, const void *buf) {
    if (!writable(v)) return -1;
    if (offset < 0 || count < 0 || count > LLONG_MAX - offset || (!buf && count)) {
        errno = EINVAL; return -1;
    }
    ntfs_inode *ni = ntfs_pathname_to_inode(v->vol, NULL, path);
    if (!ni) return -1;
    if (ni->mft_no < FILE_first_user || (ni->flags & FILE_ATTR_REPARSE_POINT)) {
        ntfs_inode_close(ni); errno = EPERM; return -1;
    }
    long long n = -1;
    ntfs_attr *na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
    if (na) {
        if (na->data_flags & (ATTR_IS_COMPRESSED | ATTR_IS_ENCRYPTED)) {
            ntfs_attr_close(na); ntfs_inode_close(ni); errno = ENOTSUP; return -1;
        }
        n = (long long)ntfs_attr_pwrite(na, offset, count, buf);
        ntfs_attr_close(na);
    }
    ntfs_inode_update_times(ni, NTFS_UPDATE_MCTIME);
    if (ntfs_inode_close(ni)) return -1;   /* never report an unflushed write as successful */
    return n;
}

static int create_node(nk_volume *v, const char *dir_path, const char *name,
                       mode_t type) {
    if (!writable(v) || !valid_name(name)) return -1;
    ntfs_inode *dir = ntfs_pathname_to_inode(v->vol, NULL, dir_path);
    if (!dir) return -1;
    ntfschar *ucs = NULL;
    int len = ntfs_mbstoucs(name, &ucs);
    /* NTFS names are at most 255 UCS-2 units; (u8) casts must never wrap. */
    if (len <= 0 || len > 255 || !ucs) { free(ucs); ntfs_inode_close(dir); errno = ENAMETOOLONG; return -1; }
    u64 existing = ntfs_inode_lookup_by_name(dir, ucs, len);
    if (existing != (u64)-1 || errno != ENOENT) {
        int saved = existing != (u64)-1 ? EEXIST : errno;
        free(ucs); ntfs_inode_close(dir); errno = saved; return -1;
    }
    ntfs_inode *ni = ntfs_create(dir, const_cpu_to_le32(0), ucs, (u8)len, type);
    free(ucs);
    int r = ni ? 0 : -1;
    if (ni && ntfs_inode_close(ni)) r = -1;
    if (ntfs_inode_close(dir)) r = -1;
    return r;
}

int nk_create(nk_volume *v, const char *dir_path, const char *name) {
    return create_node(v, dir_path, name, S_IFREG);
}

int nk_mkdir(nk_volume *v, const char *dir_path, const char *name) {
    return create_node(v, dir_path, name, S_IFDIR);
}

/* Split "/a/b/c" into parent "/a/b" (written into parent[]) and leaf "c". */
static const char *split_path(const char *path, char *parent, size_t plen_max) {
    const char *slash = strrchr(path, '/');
    if (!slash) return NULL;
    size_t plen = (size_t)(slash - path);
    if (plen == 0) { strcpy(parent, "/"); }
    else {
        if (plen >= plen_max) return NULL;
        memcpy(parent, path, plen);
        parent[plen] = '\0';
    }
    return slash + 1;
}

int nk_delete(nk_volume *v, const char *path) {
    if (!writable(v)) return -1;
    char parent[4096];
    const char *leaf = split_path(path, parent, sizeof(parent));
    if (!leaf) return -1;

    ntfs_inode *ni = ntfs_pathname_to_inode(v->vol, NULL, path);
    if (!ni) return -1;
    if (ni->mft_no < FILE_first_user) { ntfs_inode_close(ni); errno = EPERM; return -1; }
    ntfs_inode *dir = ntfs_pathname_to_inode(v->vol, NULL, parent);
    if (!dir) { ntfs_inode_close(ni); return -1; }

    ntfschar *ucs = NULL;
    int len = ntfs_mbstoucs(leaf, &ucs);
    if (len <= 0 || len > 255 || !ucs) {
        free(ucs); ntfs_inode_close(dir); ntfs_inode_close(ni); return -1;
    }

    /* ntfs_delete consumes (closes) both inodes, success or failure. */
    int r = ntfs_delete(v->vol, path, ni, dir, ucs, (u8)len);
    free(ucs);
    return r ? -1 : 0;
}

/* Rename the way ntfs-3g's FUSE front end does: link under the new name,
 * then delete the old name. Works for files and directories. */
int nk_rename(nk_volume *v, const char *old_path, const char *new_dir,
              const char *new_name) {
    if (!writable(v) || !valid_name(new_name)) return -1;
    // This primitive never replaces a destination. A transactional replacement
    // layer is required; deleting the destination first is not acceptable.
    char destination[4096];
    if (snprintf(destination, sizeof(destination), "%s/%s",
                 !strcmp(new_dir, "/") ? "" : new_dir, new_name) >= (int)sizeof(destination)) {
        errno = ENAMETOOLONG; return -1;
    }
    if (!strcmp(old_path, destination)) return 0;
    ntfs_inode *exists = ntfs_pathname_to_inode(v->vol, NULL, destination);
    if (exists) { ntfs_inode_close(exists); errno = EEXIST; return -1; }
    if (errno != ENOENT) return -1;

    ntfs_inode *ni = ntfs_pathname_to_inode(v->vol, NULL, old_path);
    if (!ni) return -1;
    if (ni->mft_no < FILE_first_user) { ntfs_inode_close(ni); errno = EPERM; return -1; }
    if ((ni->mrec->flags & MFT_RECORD_IS_DIRECTORY) &&
        !strncasecmp(destination, old_path, strlen(old_path)) && destination[strlen(old_path)] == '/') {
        ntfs_inode_close(ni); errno = EINVAL; return -1;
    }
    ntfs_inode *dir = ntfs_pathname_to_inode(v->vol, NULL, new_dir);
    if (!dir) { ntfs_inode_close(ni); return -1; }

    ntfschar *ucs = NULL;
    int len = ntfs_mbstoucs(new_name, &ucs);
    if (len <= 0 || len > 255 || !ucs) {
        free(ucs); ntfs_inode_close(dir); ntfs_inode_close(ni); return -1;
    }

    int r = ntfs_link(ni, dir, ucs, (u8)len);
    ntfs_inode_close(dir);
    ntfs_inode_close(ni);
    if (r) { free(ucs); return -1; }

    if (nk_delete(v, old_path) == 0) { free(ucs); return 0; }

    /* Deleting the old name failed — roll back the new link so the namespace
     * isn't left with two names for one file. */
    char ndir_buf[4096];
    snprintf(ndir_buf, sizeof(ndir_buf), "%s/%s",
             strcmp(new_dir, "/") == 0 ? "" : new_dir, new_name);
    ntfs_inode *nni = ntfs_pathname_to_inode(v->vol, NULL, ndir_buf);
    ntfs_inode *ndir = ntfs_pathname_to_inode(v->vol, NULL, new_dir);
    if (nni && ndir)
        ntfs_delete(v->vol, ndir_buf, nni, ndir, ucs, (u8)len);  /* consumes both */
    else {
        if (nni) ntfs_inode_close(nni);
        if (ndir) ntfs_inode_close(ndir);
    }
    free(ucs);
    return -1;
}

int nk_truncate(nk_volume *v, const char *path, long long size) {
    if (!writable(v)) return -1;
    if (size < 0) { errno = EINVAL; return -1; }
    ntfs_inode *ni = ntfs_pathname_to_inode(v->vol, NULL, path);
    if (!ni) return -1;
    if (ni->mft_no < FILE_first_user || (ni->flags & FILE_ATTR_REPARSE_POINT)) {
        ntfs_inode_close(ni); errno = EPERM; return -1;
    }
    int r = -1;
    ntfs_attr *na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
    if (na) {
        if (na->data_flags & (ATTR_IS_COMPRESSED | ATTR_IS_ENCRYPTED)) {
            ntfs_attr_close(na); ntfs_inode_close(ni); errno = ENOTSUP; return -1;
        }
        r = ntfs_attr_truncate(na, size);
        ntfs_attr_close(na);
    }
    ntfs_inode_update_times(ni, NTFS_UPDATE_MCTIME);
    if (ntfs_inode_close(ni)) r = -1;
    return r ? -1 : 0;
}

int nk_sync(nk_volume *v) {
    if (!v) return -1;
    ntfs_inode *metadata[] = {v->vol->vol_ni, v->vol->lcnbmp_ni, v->vol->mft_ni, v->vol->mftmirr_ni};
    for (size_t i = 0; i < sizeof(metadata) / sizeof(metadata[0]); i++) {
        if (metadata[i] && ntfs_inode_sync(metadata[i])) return -1;
    }
    return ntfs_device_sync(v->vol->dev) ? -1 : 0;
}

int nk_move(nk_volume *v, const char *old_path, const char *new_dir,
            const char *new_name, int replace, char *recovery_path, size_t recovery_size) {
    if (!writable(v) || !valid_name(new_name)) return -1;
    if (!recovery_path || recovery_size < 4096) { errno = EINVAL; return -1; }
    recovery_path[0] = 0;
    char destination[4096], backup[4096], backup_name[80];
    int n = snprintf(destination, sizeof(destination), "%s/%s", !strcmp(new_dir, "/") ? "" : new_dir, new_name);
    if (n < 0 || n >= (int)sizeof(destination)) { errno = ENAMETOOLONG; return -1; }
    nk_stat source, target;
    if (nk_stat_path(v, old_path, &source)) return -1;
    if (nk_stat_path(v, destination, &target)) {
        if (errno != ENOENT) return -1;
        return nk_rename(v, old_path, new_dir, new_name);
    }
    if (!strcmp(old_path, destination)) return 0;
    if (source.inode == target.inode) {
        // Case-only rename is handled below using an intermediate name.
        if (strcasecmp(old_path, destination)) return 0; // distinct hard links
    } else {
        if (!replace) { errno = EEXIST; return -1; }
        if (source.is_dir != target.is_dir) { errno = source.is_dir ? ENOTDIR : EISDIR; return -1; }
        if (target.is_dir) {
            ntfs_inode *ni = ntfs_pathname_to_inode(v->vol, NULL, destination);
            if (!ni) return -1;
            int r = ntfs_check_empty_dir(ni), saved = errno;
            ntfs_inode_close(ni);
            if (r) { errno = saved; return -1; }
        }
    }
    if (source.is_dir && !strncasecmp(destination, old_path, strlen(old_path)) &&
        destination[strlen(old_path)] == '/') { errno = EINVAL; return -1; }
    snprintf(backup_name, sizeof(backup_name), ".opencommander-recovery-%08x%08x", arc4random(), arc4random());
    n = snprintf(backup, sizeof(backup), "%s/%s", !strcmp(new_dir, "/") ? "" : new_dir, backup_name);
    if (n < 0 || n >= (int)sizeof(backup)) { errno = ENAMETOOLONG; return -1; }
    // Preserve the old destination under another name BEFORE replacing it.
    if (nk_rename(v, destination, new_dir, backup_name)) return -1;
    const char *move_source = source.inode == target.inode ? backup : old_path;
    int move_result;
    #ifdef NK_TESTING
    if (nk_test_fail_move_after_backup) {
        nk_test_fail_move_after_backup = 0;
        errno = ENOSPC;
        move_result = -1;
    } else
    #endif
    move_result = nk_rename(v, move_source, new_dir, new_name);
    if (move_result) {
        int saved = errno;
        if (nk_rename(v, backup, new_dir, new_name)) {
            snprintf(recovery_path, recovery_size, "%s", backup);
            errno = EIO;
        } else errno = saved;
        return -1;
    }
    if (source.inode != target.inode && nk_delete(v, backup)) {
        snprintf(recovery_path, recovery_size, "%s", backup);
        return -1;
    }
    return 0;
}
