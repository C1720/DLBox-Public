#ifndef BT_SHA1_H
#define BT_SHA1_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 计算 SHA1，输出 20 字节 */
void bt_sha1(const void *data, size_t len, uint8_t out[20]);

/* 计算 SHA1 并输出 40 字符小写十六进制串（out 需 41 字节） */
void bt_sha1_hex(const void *data, size_t len, char *out);

#ifdef __cplusplus
}
#endif

#endif /* BT_SHA1_H */
