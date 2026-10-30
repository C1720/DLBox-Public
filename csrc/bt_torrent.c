#include "bt_torrent.h"
#include "bt_bencode.h"
#include "bt_common.h"
#include "bt_sha1.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

static void set_err(char *err, size_t errlen, const char *msg) {
    if (err && errlen) {
        snprintf(err, errlen, "%s", msg);
    }
}

/* 拼接多段路径：path 数组元素用 / 连接 */
static char *join_path(bt_be_value *path_list) {
    bt_buf b;
    bt_buf_init(&b);
    for (size_t i = 0; i < path_list->as_list.count; i++) {
        bt_be_value *seg = &path_list->as_list.items[i];
        if (seg->type != BT_BE_STR) { bt_buf_free(&b); return NULL; }
        if (i > 0) bt_buf_append(&b, "/", 1);
        bt_buf_append(&b, seg->as_str.p, seg->as_str.len);
    }
    bt_buf_append(&b, "", 1); /* NUL */
    return (char *)b.data;
}

/* 把 tracker 字符串追加进列表（去重） */
static void add_tracker(char ***list, uint32_t *count, const char *url) {
    if (!url || !*url) return;
    for (uint32_t i = 0; i < *count; i++) {
        if (strcmp((*list)[i], url) == 0) return;
    }
    char **nl = (char **)realloc(*list, sizeof(char *) * (*count + 1));
    if (!nl) return;
    *list = nl;
    (*list)[*count] = bt_strdup(url);
    if ((*list)[*count]) (*count)++;
}

int bt_torrent_parse(const uint8_t *data, size_t len, bt_torrent *out, char *err, size_t errlen) {
    memset(out, 0, sizeof(*out));

    bt_be_value root;
    if (bt_be_decode(data, len, &root) != 0) {
        set_err(err, errlen, "不是有效的 bencode 数据");
        return -1;
    }
    if (root.type != BT_BE_DICT) {
        bt_be_free(&root);
        set_err(err, errlen, "顶层不是字典");
        return -1;
    }

    bt_be_value *info = bt_be_dict_get(&root, "info", 4);
    if (!info || info->type != BT_BE_DICT) {
        bt_be_free(&root);
        set_err(err, errlen, "缺少 info 字典");
        return -1;
    }

    /* info hash = 对 info 字典的原始字节做 SHA1 */
    bt_sha1(info->raw, info->raw_len, out->info_hash);
    bt_to_hex(out->info_hash, 20, out->info_hash_hex);

    /* 留一份 info 原始字节 */
    if (info->raw && info->raw_len > 0) {
        out->info_raw = (uint8_t *)malloc(info->raw_len);
        if (out->info_raw) {
            memcpy(out->info_raw, info->raw, info->raw_len);
            out->info_raw_len = (uint32_t)info->raw_len;
        }
    }

    /* name */
    bt_be_value *name = bt_be_dict_get(info, "name", 4);
    if (name && name->type == BT_BE_STR) out->name = bt_be_strdup(name);

    /* piece length */
    bt_be_value *plen = bt_be_dict_get(info, "piece length", 12);
    if (!plen || plen->type != BT_BE_INT || plen->as_int <= 0) {
        bt_be_free(&root);
        bt_torrent_free(out);
        set_err(err, errlen, "缺少合法的 piece length");
        return -1;
    }
    out->piece_length = (uint32_t)plen->as_int;

    /* pieces */
    bt_be_value *pieces = bt_be_dict_get(info, "pieces", 6);
    if (!pieces || pieces->type != BT_BE_STR || pieces->as_str.len % 20 != 0) {
        bt_be_free(&root);
        bt_torrent_free(out);
        set_err(err, errlen, "缺少合法的 pieces");
        return -1;
    }
    out->piece_count = (uint32_t)(pieces->as_str.len / 20);
    out->pieces = (uint8_t *)malloc(pieces->as_str.len);
    if (!out->pieces) {
        bt_be_free(&root);
        bt_torrent_free(out);
        set_err(err, errlen, "内存不足");
        return -1;
    }
    memcpy(out->pieces, pieces->as_str.p, pieces->as_str.len);

    /* 单文件 or 多文件 */
    bt_be_value *length = bt_be_dict_get(info, "length", 6);
    bt_be_value *files = bt_be_dict_get(info, "files", 5);
    if (length && length->type == BT_BE_INT) {
        out->file_count = 1;
        out->files = (bt_torrent_file *)calloc(1, sizeof(bt_torrent_file));
        if (!out->files) {
            bt_be_free(&root); bt_torrent_free(out);
            set_err(err, errlen, "内存不足"); return -1;
        }
        out->files[0].length = (uint64_t)length->as_int;
        out->files[0].path = out->name ? bt_strdup(out->name) : bt_strdup("file");
        out->total_length = (uint64_t)length->as_int;
    } else if (files && files->type == BT_BE_LIST) {
        out->file_count = (uint32_t)files->as_list.count;
        out->files = (bt_torrent_file *)calloc(out->file_count ? out->file_count : 1,
                                               sizeof(bt_torrent_file));
        if (!out->files) {
            bt_be_free(&root); bt_torrent_free(out);
            set_err(err, errlen, "内存不足"); return -1;
        }
        for (uint32_t i = 0; i < out->file_count; i++) {
            bt_be_value *f = &files->as_list.items[i];
            if (f->type != BT_BE_DICT) { bt_be_free(&root); bt_torrent_free(out); set_err(err, errlen, "files 元素非法"); return -1; }
            bt_be_value *flen = bt_be_dict_get(f, "length", 6);
            bt_be_value *fpath = bt_be_dict_get(f, "path", 4);
            if (flen && flen->type == BT_BE_INT) out->files[i].length = (uint64_t)flen->as_int;
            if (fpath && fpath->type == BT_BE_LIST) out->files[i].path = join_path(fpath);
            if (!out->files[i].path) out->files[i].path = bt_strdup("file");
            out->total_length += out->files[i].length;
        }
    } else {
        bt_be_free(&root);
        bt_torrent_free(out);
        set_err(err, errlen, "缺少 length 或 files");
        return -1;
    }

    /* tracker */
    bt_be_value *announce = bt_be_dict_get(&root, "announce", 8);
    if (announce && announce->type == BT_BE_STR) {
        char *u = bt_be_strdup(announce);
        add_tracker(&out->trackers, &out->tracker_count, u);
        free(u);
    }
    bt_be_value *alist = bt_be_dict_get(&root, "announce-list", 13);
    if (alist && alist->type == BT_BE_LIST) {
        for (size_t i = 0; i < alist->as_list.count; i++) {
            bt_be_value *tier = &alist->as_list.items[i];
            if (tier->type == BT_BE_LIST) {
                for (size_t j = 0; j < tier->as_list.count; j++) {
                    bt_be_value *u = &tier->as_list.items[j];
                    if (u->type == BT_BE_STR) {
                        char *s = bt_be_strdup(u);
                        add_tracker(&out->trackers, &out->tracker_count, s);
                        free(s);
                    }
                }
            } else if (tier->type == BT_BE_STR) {
                char *s = bt_be_strdup(tier);
                add_tracker(&out->trackers, &out->tracker_count, s);
                free(s);
            }
        }
    }

    bt_be_free(&root);
    return 0;
}

void bt_torrent_free(bt_torrent *t) {
    if (!t) return;
    free(t->name); t->name = NULL;
    free(t->pieces); t->pieces = NULL;
    if (t->files) {
        for (uint32_t i = 0; i < t->file_count; i++) free(t->files[i].path);
        free(t->files); t->files = NULL;
    }
    if (t->trackers) {
        for (uint32_t i = 0; i < t->tracker_count; i++) free(t->trackers[i]);
        free(t->trackers); t->trackers = NULL;
    }
    t->tracker_count = 0;
    t->file_count = 0;
    free(t->info_raw); t->info_raw = NULL;
    t->info_raw_len = 0;
}

static char *fmt_size(uint64_t n) {
    static char buf[64];
    if (n >= 1024 * 1024 * 1024)
        snprintf(buf, sizeof(buf), "%.2f GB", n / (1024.0 * 1024.0 * 1024.0));
    else if (n >= 1024 * 1024)
        snprintf(buf, sizeof(buf), "%.2f MB", n / (1024.0 * 1024.0));
    else if (n >= 1024)
        snprintf(buf, sizeof(buf), "%.1f KB", n / 1024.0);
    else
        snprintf(buf, sizeof(buf), "%llu B", (unsigned long long)n);
    return buf;
}

char *bt_torrent_summary(const bt_torrent *t) {
    bt_buf b;
    bt_buf_init(&b);
    char line[512];
    snprintf(line, sizeof(line), "名称: %s\n", t->name ? t->name : "(未知)");
    bt_buf_append(&b, line, strlen(line));
    snprintf(line, sizeof(line), "大小: %s\n", fmt_size(t->total_length));
    bt_buf_append(&b, line, strlen(line));
    snprintf(line, sizeof(line), "分片: %u 片 × %u 字节\n", t->piece_count, t->piece_length);
    bt_buf_append(&b, line, strlen(line));
    snprintf(line, sizeof(line), "文件数: %u\n", t->file_count);
    bt_buf_append(&b, line, strlen(line));
    snprintf(line, sizeof(line), "info hash: %s\n", t->info_hash_hex);
    bt_buf_append(&b, line, strlen(line));
    snprintf(line, sizeof(line), "tracker: %u 个\n", t->tracker_count);
    bt_buf_append(&b, line, strlen(line));
    for (uint32_t i = 0; i < t->tracker_count && i < 8; i++) {
        snprintf(line, sizeof(line), "  %s\n", t->trackers[i]);
        bt_buf_append(&b, line, strlen(line));
    }
    bt_buf_append(&b, "", 1);
    return (char *)b.data;
}
