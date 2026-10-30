#ifndef BT_MAGNET_H
#define BT_MAGNET_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 解析后的 magnet 链接 */
typedef struct bt_magnet {
    uint8_t info_hash[20];
    char info_hash_hex[41];     /* 小写 hex，用于显示 */
    char *name;                 /* dn，可为 NULL */
    char **trackers;            /* tr 列表（去重） */
    uint32_t tracker_count;
} bt_magnet;

/* 解析 magnet 链接。成功返回 0；失败返回非 0 并在 err 写信息。 */
int bt_magnet_parse(const char *url, bt_magnet *out, char *err, size_t errlen);

void bt_magnet_free(bt_magnet *m);

#ifdef __cplusplus
}
#endif

#endif /* BT_MAGNET_H */
