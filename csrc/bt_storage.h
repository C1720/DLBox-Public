#ifndef BT_STORAGE_H
#define BT_STORAGE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

struct bt_torrent_file;

typedef struct {
    int file_count;
    char **paths;      /* 完整路径 */
    int *fds;
    uint64_t *lengths;
    uint64_t *starts;  /* 每个文件在整体字节流中的起始偏移 */
    uint64_t total;
    uint32_t piece_length;
    uint32_t piece_count;
} bt_storage;

/* 打开：在 save_dir 下创建文件并预分配（truncate）。失败返回非 0。 */
int bt_storage_open(bt_storage *st, const char *name, const char *save_dir,
                    uint32_t piece_length, uint32_t piece_count,
                    const struct bt_torrent_file *files, uint32_t file_count,
                    char *err, size_t errlen);

/* 打开已存在文件（不 truncate，缺文件则创建空文件），用于做种检测/续传。
 * 失败返回非 0。 */
int bt_storage_open_read(bt_storage *st, const char *name, const char *save_dir,
                         uint32_t piece_length, uint32_t piece_count,
                         const struct bt_torrent_file *files, uint32_t file_count,
                         char *err, size_t errlen);

/* 写入一个完整 piece（index 从 0），数据跨文件自动拆分。返回 0 成功。 */
int bt_storage_write_piece(bt_storage *st, uint32_t index, const uint8_t *data, uint32_t len);

/* 按全局字节偏移读一段（跨文件拆分）。返回 0 成功。做种上传用。 */
int bt_storage_read_range(bt_storage *st, uint64_t offset, uint8_t *buf, uint32_t len);

/* 判断所有文件是否已完整（实际大小 == 期望大小）。 */
int bt_storage_is_complete(bt_storage *st);

void bt_storage_close(bt_storage *st);

#ifdef __cplusplus
}
#endif

#endif /* BT_STORAGE_H */
