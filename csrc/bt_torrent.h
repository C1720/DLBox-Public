#ifndef BT_TORRENT_H
#define BT_TORRENT_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 单个文件 */
typedef struct bt_torrent_file {
    char *path;      /* 相对路径，含子目录（用 / 连接） */
    uint64_t length;
} bt_torrent_file;

/* 解析后的 torrent 元数据 */
typedef struct {
    char *name;                 /* info.name */
    uint64_t total_length;
    uint32_t piece_length;
    uint32_t piece_count;
    uint8_t *pieces;            /* piece_count * 20 字节 SHA1 */

    uint32_t file_count;
    bt_torrent_file *files;

    /* tracker：announce-list 展开 + announce，去重 */
    char **trackers;
    uint32_t tracker_count;

    uint8_t info_hash[20];
    char info_hash_hex[41];

    /* info 字典原始字节（做种时供别的 magnet 客户端拉取元数据，BEP-9） */
    uint8_t *info_raw;
    uint32_t info_raw_len;
} bt_torrent;

/* 解析 .torrent 字节。成功返回 0，失败返回非 0（err 写错误信息）。 */
int bt_torrent_parse(const uint8_t *data, size_t len, bt_torrent *out, char *err, size_t errlen);

/* 释放 */
void bt_torrent_free(bt_torrent *t);

/* 输出人类可读摘要（调用方 free） */
char *bt_torrent_summary(const bt_torrent *t);

#ifdef __cplusplus
}
#endif

#endif /* BT_TORRENT_H */
