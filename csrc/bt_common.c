#include "bt_common.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <sys/socket.h>

void bt_buf_init(bt_buf *b) {
    b->data = NULL;
    b->len = 0;
    b->cap = 0;
}

void bt_buf_free(bt_buf *b) {
    if (b->data) { free(b->data); b->data = NULL; }
    b->len = 0;
    b->cap = 0;
}

int bt_buf_reserve(bt_buf *b, size_t need) {
    if (b->cap >= need) return 0;
    size_t ncap = b->cap ? b->cap : 256;
    while (ncap < need) {
        if (ncap > (size_t)1 << 30) return -1;
        ncap *= 2;
    }
    uint8_t *nd = (uint8_t *)realloc(b->data, ncap);
    if (!nd) return -1;
    b->data = nd;
    b->cap = ncap;
    return 0;
}

int bt_buf_append(bt_buf *b, const void *data, size_t len) {
    if (bt_buf_reserve(b, b->len + len) != 0) return -1;
    if (len) memcpy(b->data + b->len, data, len);
    b->len += len;
    return 0;
}

void bt_buf_reset(bt_buf *b) { b->len = 0; }

void bt_to_hex(const uint8_t *data, size_t len, char *out) {
    static const char *hx = "0123456789abcdef";
    for (size_t i = 0; i < len; i++) {
        out[i * 2] = hx[data[i] >> 4];
        out[i * 2 + 1] = hx[data[i] & 0xf];
    }
    out[len * 2] = '\0';
}

char *bt_strdup(const char *s) {
    if (!s) return NULL;
    size_t n = strlen(s);
    char *r = (char *)malloc(n + 1);
    if (!r) return NULL;
    memcpy(r, s, n + 1);
    return r;
}

char *bt_strndup(const char *s, size_t n) {
    char *r = (char *)malloc(n + 1);
    if (!r) return NULL;
    memcpy(r, s, n);
    r[n] = '\0';
    return r;
}

void bt_random_bytes(uint8_t *buf, size_t len) {
#if defined(__APPLE__)
    arc4random_buf(buf, len);
#else
    /* host（测试用）回退到 rand()，非密码学安全，仅编译测试 */
    for (size_t i = 0; i < len; i++) buf[i] = (uint8_t)rand();
#endif
}

void bt_make_peer_id(uint8_t out[20]) {
    static const char *prefix = "-DL01";
    memcpy(out, prefix, 5);
    /* 后 15 字节用随机可见字符，避免偶发二进制内容 */
    static const char *chars = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
    for (int i = 5; i < 20; i++) {
#if defined(__APPLE__)
        uint32_t r = arc4random_uniform(62);
#else
        uint32_t r = (uint32_t)(rand() % 62);
#endif
        out[i] = (uint8_t)chars[r];
    }
}

/* Darwin: 往已 RST 的 TCP 连接 send() 会触发 SIGPIPE，默认动作是终止进程。
 * 每个 socket 都必须关掉它，否则连接一多就会出现「下载到一半闪退」。 */
void bt_set_nosigpipe(int fd) {
#ifdef SO_NOSIGPIPE
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#else
    (void)fd;
#endif
}
