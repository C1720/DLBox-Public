#ifndef BT_TRACKER_H
#define BT_TRACKER_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* peer 地址（IPv4 / IPv6 统一表示） */
typedef struct bt_peer_addr {
    uint8_t ip[16];      /* IPv4 用前 4 字节；IPv6 用全部 16 字节 */
    uint16_t port;
    int is_ipv6;         /* 1 = IPv6，0 = IPv4 */
} bt_peer_addr;

/* 格式化地址为可读字符串（返回静态缓冲区，非线程安全，仅日志用） */
const char *bt_peer_addr_str(const bt_peer_addr *a);

/* 百分号编码（RFC 3986 的 unreserved 之外全部编码为 %XX 大写）。dst 需至少 3*len+1。 */
void bt_tracker_url_encode(const uint8_t *src, size_t len, char *dst, size_t dstlen);

/* 解析 announce 响应的 bencode body，提取 peers（compact）/ interval / complete / incomplete。
 * 成功返回 0；失败（含 tracker 的 failure reason）返回非 0 并在 err 写信息。 */
int bt_tracker_parse_response(const uint8_t *body, size_t body_len,
                              bt_peer_addr **out_peers, int *out_count,
                              int *out_interval, int *out_seeders, int *out_leechers,
                              char *err, size_t errlen);

/*
 * 向 HTTP tracker 发起一次 announce（内置裸 socket 实现，仅 http://）。
 * tracker_url: http://host[:port]/path
 * event: "started" / "completed" / "stopped" / NULL(常规)
 * 成功返回 0，peers 通过 malloc 分配（调用方 free）。
 */
int bt_tracker_announce(
    const char *tracker_url,
    const uint8_t info_hash[20],
    const uint8_t peer_id[20],
    uint16_t local_port,
    int64_t uploaded,
    int64_t downloaded,
    int64_t left,
    const char *event,
    bt_peer_addr **out_peers,
    int *out_count,
    int *out_interval,
    int *out_seeders,
    int *out_leechers,
    char *err, size_t errlen);

#ifdef __cplusplus
}
#endif

#endif /* BT_TRACKER_H */
