#ifndef BT_COMMON_H
#define BT_COMMON_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 动态字节缓冲：网络收发、bencode 解析复用 */
typedef struct {
    uint8_t *data;
    size_t len;
    size_t cap;
} bt_buf;

void bt_buf_init(bt_buf *b);
void bt_buf_free(bt_buf *b);
int  bt_buf_reserve(bt_buf *b, size_t need);
int  bt_buf_append(bt_buf *b, const void *data, size_t len);
void bt_buf_reset(bt_buf *b);

/* 十六进制字符串（out 需至少 2*len+1 字节） */
void bt_to_hex(const uint8_t *data, size_t len, char *out);

char *bt_strdup(const char *s);
char *bt_strndup(const char *s, size_t n);

/* 安全随机字节（iOS 走 arc4random_buf） */
void bt_random_bytes(uint8_t *buf, size_t len);

/* 生成标准 peer_id：-DL01xx- + 12 随机 ASCII */
void bt_make_peer_id(uint8_t out[20]);

/* 关闭该 socket 的 SIGPIPE（Darwin 专属），必须对每个 TCP fd 调用 */
void bt_set_nosigpipe(int fd);

#ifdef __cplusplus
}
#endif

#endif /* BT_COMMON_H */
