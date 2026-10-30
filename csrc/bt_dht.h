#ifndef BT_DHT_H
#define BT_DHT_H

#include <stdint.h>
#include <stddef.h>
#include "bt_tracker.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct bt_dht bt_dht;

typedef void (*bt_dht_log_fn)(void *ctx, const char *line);

/* 创建 DHT 客户端。
 * node_id：20 字节节点 ID（传 NULL 则随机生成）。
 * port：对外宣告的 UDP/TCP 端口（做种时别人据此回连）。 */
bt_dht *bt_dht_create(const uint8_t node_id[20], uint16_t port,
                      bt_dht_log_fn log, void *ctx);

void bt_dht_destroy(bt_dht *d);

/* 查询 info_hash 对应的 peers。阻塞，最多 timeout_sec 秒。
 * 成功返回 0（即使找到 0 个也是成功，count=0）。peers 由 malloc 分配，调用方 free。 */
int bt_dht_get_peers(bt_dht *d, const uint8_t info_hash[20],
                     bt_peer_addr **out_peers, int *out_count,
                     int want, int timeout_sec);

/* 向 DHT 宣告自己拥有 info_hash（做种/下载中），供其他节点发现。返回 0 成功。 */
int bt_dht_announce(bt_dht *d, const uint8_t info_hash[20], uint16_t port);

/* 当前路由表节点数。 */
int bt_dht_node_count(const bt_dht *d);

/* 把一个已知地址（如 tracker 返回的 peer）当作 DHT 入口节点塞进路由表。
 * 公共 bootstrap 节点在国内经常被墙 / 超时，用真实 peer 当入口能让路由表
 * 快速长起来。只处理 IPv4（DHT 目前只支持 IPv4）。 */
void bt_dht_add_node(bt_dht *d, const bt_peer_addr *a);

#ifdef __cplusplus
}
#endif

#endif /* BT_DHT_H */
