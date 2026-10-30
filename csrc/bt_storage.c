#include "bt_storage.h"
#include "bt_torrent.h"
#include "bt_common.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <errno.h>

/* 递归创建目录 */
static int mkdir_p(const char *path) {
    char tmp[1024];
    size_t n = strlen(path);
    if (n >= sizeof(tmp)) return -1;
    memcpy(tmp, path, n + 1);
    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/') {
            *p = '\0';
            if (mkdir(tmp, 0755) != 0 && errno != EEXIST) return -1;
            *p = '/';
        }
    }
    if (mkdir(tmp, 0755) != 0 && errno != EEXIST) return -1;
    return 0;
}

/* 相对路径净化：跳过 ".."、空段、以 / 开头段；返回拼接后安全相对路径 */
static char *sanitize_relpath(const char *rel) {
    bt_buf b;
    bt_buf_init(&b);
    const char *p = rel;
    while (p && *p) {
        const char *slash = strchr(p, '/');
        size_t seglen = slash ? (size_t)(slash - p) : strlen(p);
        if (seglen > 0 && !(seglen == 1 && p[0] == '.') &&
            !(seglen == 2 && p[0] == '.' && p[1] == '.')) {
            if (b.len > 0) bt_buf_append(&b, "/", 1);
            bt_buf_append(&b, p, seglen);
        }
        p = slash ? slash + 1 : NULL;
    }
    bt_buf_append(&b, "", 1);
    return (char *)b.data;
}

static int bt_storage_open_internal(bt_storage *st, const char *name, const char *save_dir,
                                    uint32_t piece_length, uint32_t piece_count,
                                    const bt_torrent_file *files, uint32_t file_count,
                                    int truncate_existing,
                                    char *err, size_t errlen);

int bt_storage_open(bt_storage *st, const char *name, const char *save_dir,
                    uint32_t piece_length, uint32_t piece_count,
                    const bt_torrent_file *files, uint32_t file_count,
                    char *err, size_t errlen)
{
    return bt_storage_open_internal(st, name, save_dir, piece_length, piece_count,
                                    files, file_count, 1, err, errlen);
}

int bt_storage_open_read(bt_storage *st, const char *name, const char *save_dir,
                         uint32_t piece_length, uint32_t piece_count,
                         const bt_torrent_file *files, uint32_t file_count,
                         char *err, size_t errlen)
{
    return bt_storage_open_internal(st, name, save_dir, piece_length, piece_count,
                                    files, file_count, 0, err, errlen);
}

static int bt_storage_open_internal(bt_storage *st, const char *name, const char *save_dir,
                                    uint32_t piece_length, uint32_t piece_count,
                                    const bt_torrent_file *files, uint32_t file_count,
                                    int truncate_existing,
                                    char *err, size_t errlen)
{
    memset(st, 0, sizeof(*st));
    st->piece_length = piece_length;
    st->piece_count = piece_count;

    /* 单文件：save_dir/name；多文件：save_dir/name/<relpath> */
    char base[2048];
    const char *safe_name = (name && *name) ? name : "download";
    if (file_count == 1 && !strchr(files[0].path, '/')) {
        snprintf(base, sizeof(base), "%s", save_dir);
    } else {
        snprintf(base, sizeof(base), "%s/%s", save_dir, safe_name);
    }
    if (mkdir_p(base) != 0) {
        snprintf(err, errlen, "无法创建目录 %s", base);
        return -1;
    }

    st->file_count = (int)file_count;
    st->paths = (char **)calloc(file_count ? file_count : 1, sizeof(char *));
    st->fds = (int *)malloc(sizeof(int) * (file_count ? file_count : 1));
    st->lengths = (uint64_t *)calloc(file_count ? file_count : 1, sizeof(uint64_t));
    st->starts = (uint64_t *)calloc(file_count ? file_count : 1, sizeof(uint64_t));
    if (!st->paths || !st->fds || !st->lengths || !st->starts) {
        snprintf(err, errlen, "内存不足");
        bt_storage_close(st);
        return -1;
    }

    uint64_t off = 0;
    for (uint32_t i = 0; i < file_count; i++) {
        const char *rel = files[i].path ? files[i].path : "file";
        char *safe_rel = sanitize_relpath(rel);
        const char *seg = safe_rel ? safe_rel : "file";
        /* 单文件：full = save_dir/name；多文件：full = save_dir/name/<relpath> */
        size_t need = strlen(base) + 1 + strlen(seg) + 1;
        char *full = (char *)malloc(need);
        snprintf(full, need, "%s/%s", base, seg);
        free(safe_rel);

        /* 确保父目录存在 */
        char *slash = strrchr(full, '/');
        if (slash) {
            char dircopy[2048];
            size_t dl = (size_t)(slash - full);
            if (dl < sizeof(dircopy)) {
                memcpy(dircopy, full, dl);
                dircopy[dl] = '\0';
                mkdir_p(dircopy);
            }
        }

        int flags = O_RDWR | O_CREAT;
        if (truncate_existing) flags |= O_TRUNC;
        int fd = open(full, flags, 0644);
        if (fd < 0) {
            snprintf(err, errlen, "无法创建文件 %s", full);
            free(full);
            bt_storage_close(st);
            return -1;
        }
        if (truncate_existing && ftruncate(fd, (off_t)files[i].length) != 0) {
            snprintf(err, errlen, "无法预分配 %s", full);
            close(fd);
            free(full);
            bt_storage_close(st);
            return -1;
        }
        st->paths[i] = full;
        st->fds[i] = fd;
        st->lengths[i] = files[i].length;
        st->starts[i] = off;
        off += files[i].length;
    }
    st->total = off;
    return 0;
}

int bt_storage_write_piece(bt_storage *st, uint32_t index, const uint8_t *data, uint32_t len) {
    if (index >= st->piece_count) return -1;
    uint64_t poff = (uint64_t)index * st->piece_length;
    if (poff >= st->total) return -1;
    uint64_t remaining = len;
    const uint8_t *src = data;

    for (int i = 0; i < st->file_count && remaining > 0; i++) {
        uint64_t fstart = st->starts[i];
        uint64_t fend = fstart + st->lengths[i];
        if (poff >= fend) continue;
        uint64_t in_file = fend - poff;
        uint64_t to_write = remaining < in_file ? remaining : in_file;
        uint64_t foff = poff - fstart;
        /* 循环写入，处理部分写 */
        uint64_t written = 0;
        while (written < to_write) {
            ssize_t w = pwrite(st->fds[i], src + written, (size_t)(to_write - written),
                               (off_t)(foff + written));
            if (w <= 0) return -1;
            written += (uint64_t)w;
        }
        src += to_write;
        poff += to_write;
        remaining -= to_write;
    }
    return remaining == 0 ? 0 : -1;
}

int bt_storage_read_range(bt_storage *st, uint64_t offset, uint8_t *buf, uint32_t len) {
    if (offset + len > st->total) return -1;
    uint64_t remaining = len;
    uint8_t *dst = buf;
    uint64_t poff = offset;

    for (int i = 0; i < st->file_count && remaining > 0; i++) {
        uint64_t fstart = st->starts[i];
        uint64_t fend = fstart + st->lengths[i];
        if (poff >= fend) continue;
        uint64_t in_file = fend - poff;
        uint64_t to_read = remaining < in_file ? remaining : in_file;
        uint64_t foff = poff - fstart;
        uint64_t got = 0;
        while (got < to_read) {
            ssize_t r = pread(st->fds[i], dst + got, (size_t)(to_read - got),
                              (off_t)(foff + got));
            if (r <= 0) return -1;
            got += (uint64_t)r;
        }
        dst += to_read;
        poff += to_read;
        remaining -= to_read;
    }
    return remaining == 0 ? 0 : -1;
}

int bt_storage_is_complete(bt_storage *st) {
    for (int i = 0; i < st->file_count; i++) {
        struct stat sb;
        if (fstat(st->fds[i], &sb) != 0) return 0;
        if ((uint64_t)sb.st_size != st->lengths[i]) return 0;
    }
    return 1;
}

void bt_storage_close(bt_storage *st) {
    if (st->fds) {
        for (int i = 0; i < st->file_count; i++) {
            if (st->fds[i] > 0) close(st->fds[i]);
        }
        free(st->fds);
        st->fds = NULL;
    }
    if (st->paths) {
        for (int i = 0; i < st->file_count; i++) free(st->paths[i]);
        free(st->paths);
        st->paths = NULL;
    }
    free(st->lengths); st->lengths = NULL;
    free(st->starts); st->starts = NULL;
    st->file_count = 0;
}
