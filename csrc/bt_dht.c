#include "bt_dht.h"
#include "bt_bencode.h"
#include "bt_common.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <time.h>

#define DHT_MAX_NODES 512
#define DHT_QUERY_TIMEOUT_MS 700
#define DHT_PACKET_MAX 4096

static const struct { const char *host; uint16_t port; } DHT_BOOTSTRAP[] = {
    { "router.bittorrent.com", 6881 },
    { "router.utorrent.com", 6881 },
    { "dht.transmissionbt.com", 6881 },
    { "router.bitcomet.com", 6881 },
    { "dht.libtorrent.org", 25401 },
    { "router.silotis.us", 6881 },
    { "dht.aelitis.com", 6881 },
};

typedef struct {
    uint8_t id[20];
    uint8_t ip[4];
    uint16_t port;
    time_t last_seen;
    time_t last_queried;
    int good;
    int seed;       /* 1 = tracker/peer 提供的入口节点，优先查询一次 */
} dht_node;

struct bt_dht {
    uint8_t id[20];
    int sock;
    uint16_t port;          /* 对外宣告端口 */
    bt_dht_log_fn log;
    void *ctx;
    dht_node nodes[DHT_MAX_NODES];
    int node_count;
    time_t last_bootstrap;
    /* 最近一次 get_peers 得到的 token（用于 announce_peer） */
    uint8_t token[64];
    int token_len;
    uint8_t token_ip[4];
    uint16_t token_port;
};

static void dlog(bt_dht *d, const char *fmt, ...) {
    if (!d->log) return;
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    d->log(d->ctx, buf);
}

/* XOR 距离比较：返回 -1 表示 a 更接近 target，1 表示 b 更近，0 相等 */
static int xor_cmp(const uint8_t *a, const uint8_t *b, const uint8_t *target) {
    for (int i = 0; i < 20; i++) {
        uint8_t xa = (uint8_t)(a[i] ^ target[i]);
        uint8_t xb = (uint8_t)(b[i] ^ target[i]);
        if (xa != xb) return xa < xb ? -1 : 1;
    }
    return 0;
}

static int node_find(bt_dht *d, const uint8_t *ip, uint16_t port) {
    for (int i = 0; i < d->node_count; i++) {
        if (memcmp(d->nodes[i].ip, ip, 4) == 0 && d->nodes[i].port == port)
            return i;
    }
    return -1;
}

static void node_add(bt_dht *d, const uint8_t *id, const uint8_t *ip, uint16_t port) {
    if (!ip || port == 0) return;
    /* 忽略自己 */
    if (memcmp(id, d->id, 20) == 0) return;

    int idx = node_find(d, ip, port);
    if (idx >= 0) {
        /* 已有：补全 id，刷新时间 */
        memcpy(d->nodes[idx].id, id, 20);
        d->nodes[idx].last_seen = time(NULL);
        return;
    }
    if (d->node_count < DHT_MAX_NODES) {
        dht_node *n = &d->nodes[d->node_count++];
        memset(n, 0, sizeof(*n));
        memcpy(n->id, id, 20);
        memcpy(n->ip, ip, 4);
        n->port = port;
        n->last_seen = time(NULL);
        return;
    }
    /* 满：淘汰最久未见的非 good 节点 */
    int victim = -1;
    time_t oldest = 0;
    for (int i = 0; i < d->node_count; i++) {
        if (!d->nodes[i].good) {
            if (victim < 0 || d->nodes[i].last_seen < oldest) {
                victim = i;
                oldest = d->nodes[i].last_seen;
            }
        }
    }
    if (victim < 0) return; /* 全是 good，暂不淘汰 */
    dht_node *n = &d->nodes[victim];
    memset(n, 0, sizeof(*n));
    memcpy(n->id, id, 20);
    memcpy(n->ip, ip, 4);
    n->port = port;
    n->last_seen = time(NULL);
}

/* 解析 compact nodes（26 字节一组：20 id + 4 ip + 2 port）加入路由表 */
static void nodes_parse_add(bt_dht *d, const uint8_t *p, size_t len) {
    for (size_t i = 0; i + 26 <= len; i += 26) {
        node_add(d, p + i, p + i + 20,
                 (uint16_t)((p[i + 24] << 8) | p[i + 25]));
    }
}

/* ---------- 单次查询（发送 + 等待匹配响应） ---------- */

static void query_encode(bt_dht *d, const char *qtype, bt_be_value *a,
                         uint8_t *out, size_t *out_len) {
    bt_be_value msg;
    memset(&msg, 0, sizeof(msg));
    msg.type = BT_BE_DICT;

    uint8_t tid[4];
    bt_random_bytes(tid, sizeof(tid));
    bt_be_value t = bt_be_strn(tid, sizeof(tid));
    bt_be_dict_set(&msg, "t", &t);

    bt_be_value y = bt_be_str("q");
    bt_be_dict_set(&msg, "y", &y);

    bt_be_value q = bt_be_str(qtype);
    bt_be_dict_set(&msg, "q", &q);

    /* 深拷贝 a，避免 bt_be_free(&msg) 连带释放调用者的 a */
    bt_be_value aclone = bt_be_clone(a);
    bt_be_dict_set(&msg, "a", &aclone);

    size_t len = 0;
    uint8_t *enc = bt_be_encode(&msg, &len);
    if (enc && len <= *out_len) {
        memcpy(out, enc, len);
        *out_len = len;
    } else if (enc) {
        *out_len = 0;
    }
    free(enc);
    bt_be_free(&msg);
}

/* 发送查询并阻塞等待响应。
 * 成功返回 0，*out_r 为响应 r 字典（调用方 bt_be_free）。超时/错误返回 -1。
 * 顺带把响应对端节点标记 good（由调用方传入节点引用）。 */
static int dht_query(bt_dht *d, dht_node *node, const char *qtype, bt_be_value *a,
                     bt_be_value *out_r) {
    uint8_t pkt[DHT_PACKET_MAX];
    size_t pkt_len = sizeof(pkt);
    query_encode(d, qtype, a, pkt, &pkt_len);
    if (pkt_len == 0) return -1;

    struct sockaddr_in to;
    memset(&to, 0, sizeof(to));
    to.sin_family = AF_INET;
    to.sin_port = htons(node->port);
    memcpy(&to.sin_addr.s_addr, node->ip, 4);
    if (sendto(d->sock, pkt, pkt_len, 0, (struct sockaddr *)&to, sizeof(to)) < 0) {
        dlog(d, "DHT sendto 失败 errno=%d（%s）", errno, strerror(errno));
        return -1;
    }

    /* 解析我们自己发出的 tid，用于匹配 */
    bt_be_value dec;
    if (bt_be_decode(pkt, pkt_len, &dec) != 0) return -1;
    bt_be_value *t = bt_be_dict_get(&dec, "t", 1);
    char tid[16]; size_t tid_len = 0;
    if (t && t->type == BT_BE_STR) {
        tid_len = t->as_str.len < 16 ? t->as_str.len : 16;
        memcpy(tid, t->as_str.p, tid_len);
    }
    bt_be_free(&dec);

    time_t deadline = time(NULL) + (DHT_QUERY_TIMEOUT_MS / 1000) + 1;
    for (;;) {
        struct timeval tv = { 0, 200000 }; /* 200ms 轮询 */
        fd_set rf;
        FD_ZERO(&rf);
        FD_SET(d->sock, &rf);
        int sr = select(d->sock + 1, &rf, NULL, NULL, &tv);
        if (sr < 0) return -1;
        if (sr == 0) {
            if (time(NULL) >= deadline) return -1;
            continue;
        }
        uint8_t buf[DHT_PACKET_MAX];
        struct sockaddr_in from;
        socklen_t flen = sizeof(from);
        ssize_t n = recvfrom(d->sock, buf, sizeof(buf), 0, (struct sockaddr *)&from, &flen);
        if (n <= 0) continue;
        /* 只接受来自目标节点的响应 */
        if (from.sin_port != htons(node->port) ||
            memcmp(&from.sin_addr.s_addr, node->ip, 4) != 0) continue;

        bt_be_value resp;
        if (bt_be_decode(buf, (size_t)n, &resp) != 0) continue;
        bt_be_value *rt = bt_be_dict_get(&resp, "t", 1);
        if (!rt || rt->type != BT_BE_STR || rt->as_str.len != tid_len ||
            memcmp(rt->as_str.p, tid, tid_len) != 0) {
            bt_be_free(&resp);
            continue;
        }
        bt_be_value *y = bt_be_dict_get(&resp, "y", 1);
        if (y && y->type == BT_BE_STR && y->as_str.len == 1 && y->as_str.p[0] == 'r') {
            bt_be_value *r = bt_be_dict_get(&resp, "r", 1);
            if (r && r->type == BT_BE_DICT) {
                *out_r = bt_be_clone(r);
                node->good = 1;
                node->last_seen = time(NULL);
                bt_be_free(&resp);
                return 0;
            }
        }
        bt_be_free(&resp);
    }
}

/* ---------- 对外实现 ---------- */

bt_dht *bt_dht_create(const uint8_t node_id[20], uint16_t port,
                      bt_dht_log_fn log, void *ctx) {
    bt_dht *d = (bt_dht *)calloc(1, sizeof(bt_dht));
    if (!d) return NULL;
    if (node_id) memcpy(d->id, node_id, 20);
    else bt_random_bytes(d->id, 20);
    d->port = port;
    d->log = log;
    d->ctx = ctx;

    d->sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (d->sock < 0) {
        free(d);
        return NULL;
    }
    /* 非阻塞 */
    int fl = fcntl(d->sock, F_GETFL, 0);
    fcntl(d->sock, F_SETFL, fl | O_NONBLOCK);

    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_addr.s_addr = INADDR_ANY;
    sa.sin_port = htons(port);
    if (bind(d->sock, (struct sockaddr *)&sa, sizeof(sa)) != 0) {
        /* 端口被占，退回随机端口 */
        sa.sin_port = 0;
        if (bind(d->sock, (struct sockaddr *)&sa, sizeof(sa)) != 0) {
            close(d->sock);
            free(d);
            return NULL;
        }
    }
    return d;
}

void bt_dht_destroy(bt_dht *d) {
    if (!d) return;
    if (d->sock >= 0) close(d->sock);
    free(d);
}

int bt_dht_node_count(const bt_dht *d) {
    return d ? d->node_count : 0;
}

void bt_dht_add_node(bt_dht *d, const bt_peer_addr *a) {
    if (!d || !a || a->port == 0) return;
    if (a->is_ipv6) return;                 /* DHT 目前只支持 IPv4 */
    uint8_t tmp_id[20];
    bt_random_bytes(tmp_id, 20);
    node_add(d, tmp_id, a->ip, a->port);
    int idx = node_find(d, a->ip, a->port);
    if (idx >= 0) {
        d->nodes[idx].seed = 1;
        d->nodes[idx].last_queried = 0;
        d->nodes[idx].good = 0;
    }
}

/* 构造 query 的 a 字典公共部分 */
static void a_dict_init(bt_be_value *a) {
    memset(a, 0, sizeof(*a));
    a->type = BT_BE_DICT;
}

static void a_dict_add_id(bt_dht *d, bt_be_value *a) {
    bt_be_value id = bt_be_strn(d->id, 20);
    bt_be_dict_set(a, "id", &id);
}

/* bootstrap：连公共节点 find_node 填路由表 */
static void dht_bootstrap(bt_dht *d) {
    int nb = (int)(sizeof(DHT_BOOTSTRAP) / sizeof(DHT_BOOTSTRAP[0]));
    for (int i = 0; i < nb; i++) {
        struct addrinfo hints, *res = NULL;
        memset(&hints, 0, sizeof(hints));
        hints.ai_family = AF_INET;
        hints.ai_socktype = SOCK_DGRAM;
        if (getaddrinfo(DHT_BOOTSTRAP[i].host, NULL, &hints, &res) != 0 || !res) {
            dlog(d, "bootstrap %s 域名解析失败", DHT_BOOTSTRAP[i].host);
            continue;
        }
        uint8_t ip[4];
        memcpy(ip, &((struct sockaddr_in *)res->ai_addr)->sin_addr.s_addr, 4);
        freeaddrinfo(res);

        dht_node n;
        memset(&n, 0, sizeof(n));
        memcpy(n.ip, ip, 4);
        n.port = DHT_BOOTSTRAP[i].port;
        n.last_seen = time(NULL);

        bt_be_value a;
        a_dict_init(&a);
        a_dict_add_id(d, &a);
        bt_be_value tg = bt_be_strn(d->id, 20);
        bt_be_dict_set(&a, "target", &tg);

        bt_be_value r;
        if (dht_query(d, &n, "find_node", &a, &r) == 0) {
            bt_be_value *nodes = bt_be_dict_get(&r, "nodes", 5);
            int added = 0;
            if (nodes && nodes->type == BT_BE_STR) {
                added = (int)(nodes->as_str.len / 26);
                nodes_parse_add(d, nodes->as_str.p, nodes->as_str.len);
            }
            dlog(d, "bootstrap %s:%u 响应，+%d 节点（路由表 %d）",
                 DHT_BOOTSTRAP[i].host, DHT_BOOTSTRAP[i].port, added, d->node_count);
            bt_be_free(&r);
        } else {
            dlog(d, "bootstrap %s:%u 无响应（超时）", DHT_BOOTSTRAP[i].host, DHT_BOOTSTRAP[i].port);
        }
        bt_be_free(&a);
    }
    dlog(d, "DHT bootstrap 完成，路由表 %d 个节点", d->node_count);
    d->last_bootstrap = time(NULL);
}

/* 选一批离 target 最近的、最近未查询过的节点 */
static int pick_nodes(bt_dht *d, const uint8_t *target, dht_node **out, int want) {
    int picked = 0;
    time_t now = time(NULL);
    /* 0) 先打入口节点（tracker 给的 peer）。国内公共 bootstrap 经常全超时，
     *    这些入口是唯一能把路由表撑起来的种子，每个只用一次。 */
    for (int i = 0; i < d->node_count && picked < want && picked < 2; i++) {
        if (!d->nodes[i].seed) continue;
        if (now - d->nodes[i].last_queried < 15) continue;
        out[picked++] = &d->nodes[i];
        d->nodes[i].last_queried = now;
        d->nodes[i].seed = 0;
    }
    /* 简化选择：遍历所有节点，按距离排序取前 want 个未在 15s 内查询过的 */
    for (int round = 0; round < d->node_count && picked < want; round++) {
        int best = -1;
        for (int i = 0; i < d->node_count; i++) {
            if (now - d->nodes[i].last_queried < 15) continue;
            if (best < 0 ||
                xor_cmp(d->nodes[i].id, d->nodes[best].id, target) < 0) {
                best = i;
            }
        }
        if (best < 0) break;
        out[picked++] = &d->nodes[best];
        d->nodes[best].last_queried = now;
    }
    return picked;
}

/* 用路由表里已有的节点继续 find_node，把邻居节点加进表里。
 * 只有 bootstrap 那一层的话，网络一抖就永远卡在 1 个节点上。 */
static void expand_nodes(bt_dht *d, int want_nodes) {
    if (d->node_count <= 0) return;
    dht_node *batch[2];
    int n = pick_nodes(d, d->id, batch, 2);
    for (int i = 0; i < n; i++) {
        bt_be_value a;
        a_dict_init(&a);
        a_dict_add_id(d, &a);
        bt_be_value tg = bt_be_strn(d->id, 20);
        bt_be_dict_set(&a, "target", &tg);
        bt_be_value r;
        if (dht_query(d, batch[i], "find_node", &a, &r) == 0) {
            bt_be_value *nodes = bt_be_dict_get(&r, "nodes", 5);
            if (nodes && nodes->type == BT_BE_STR)
                nodes_parse_add(d, nodes->as_str.p, nodes->as_str.len);
            bt_be_free(&r);
        }
        bt_be_free(&a);
        if (d->node_count >= want_nodes) break;
    }
}

int bt_dht_get_peers(bt_dht *d, const uint8_t info_hash[20],
                     bt_peer_addr **out_peers, int *out_count,
                     int want, int timeout_sec) {
    if (out_peers) *out_peers = NULL;
    if (out_count) *out_count = 0;
    if (!d) return -1;

    /* 路由表小就一直重试 bootstrap（原来只在 ==0 时试一次，
     * 只要侥幸留下 1 个节点，路由表就永远冻结在 1 个，DHT 等于死） */
    if (d->node_count < 8 && time(NULL) - d->last_bootstrap > 30) {
        dht_bootstrap(d);
        expand_nodes(d, 60);
        dlog(d, "DHT 路由表扩充后 %d 个节点", d->node_count);
    } else if (d->node_count < 120 && time(NULL) - d->last_bootstrap > 120) {
        expand_nodes(d, 200);
        d->last_bootstrap = time(NULL);
    }
    if (d->node_count == 0) {
        dlog(d, "DHT 无可用节点（bootstrap 失败）");
        return 0;
    }

    bt_peer_addr *list = NULL;
    int count = 0, cap = 0;

    time_t deadline = time(NULL) + (timeout_sec > 0 ? timeout_sec : 20);

    while (time(NULL) < deadline && count < want) {
        dht_node *batch[8];
        int n = pick_nodes(d, info_hash, batch, 8);
        if (n == 0) break;

        for (int i = 0; i < n; i++) {
            bt_be_value a;
            a_dict_init(&a);
            a_dict_add_id(d, &a);
            bt_be_value ih = bt_be_strn(info_hash, 20);
            bt_be_dict_set(&a, "info_hash", &ih);

            bt_be_value r;
            if (dht_query(d, batch[i], "get_peers", &a, &r) == 0) {
                bt_be_value *token = bt_be_dict_get(&r, "token", 5);
                if (token && token->type == BT_BE_STR && token->as_str.len <= sizeof(d->token)) {
                    d->token_len = (int)token->as_str.len;
                    memcpy(d->token, token->as_str.p, d->token_len);
                    memcpy(d->token_ip, batch[i]->ip, 4);
                    d->token_port = batch[i]->port;
                }
                bt_be_value *values = bt_be_dict_get(&r, "values", 6);
                if (values && values->type == BT_BE_LIST) {
                    for (size_t j = 0; j < values->as_list.count; j++) {
                        bt_be_value *v = &values->as_list.items[j];
                        if (v->type != BT_BE_STR || v->as_str.len != 6) continue;
                        const uint8_t *p = v->as_str.p;
                        /* 去重 */
                        int dup = 0;
                        for (int k = 0; k < count; k++) {
                            if (memcmp(list[k].ip, p, 4) == 0 &&
                                list[k].port == (uint16_t)((p[4] << 8) | p[5])) {
                                dup = 1; break;
                            }
                        }
                        if (dup) continue;
                        if (count >= cap) {
                            cap = cap ? cap * 2 : 32;
                            bt_peer_addr *nl = (bt_peer_addr *)realloc(list, sizeof(bt_peer_addr) * cap);
                            if (!nl) { free(list); bt_be_free(&r); bt_be_free(&a); return -1; }
                            list = nl;
                        }
                        memcpy(list[count].ip, p, 4);
                        list[count].port = (uint16_t)((p[4] << 8) | p[5]);
                        list[count].is_ipv6 = 0;
                        count++;
                    }
                }
                bt_be_value *nodes = bt_be_dict_get(&r, "nodes", 5);
                if (nodes && nodes->type == BT_BE_STR)
                    nodes_parse_add(d, nodes->as_str.p, nodes->as_str.len);
                bt_be_free(&r);
            }
            bt_be_free(&a);
        }
    }

    dlog(d, "DHT 查询 info_hash 得到 %d 个 peer（路由表 %d 节点）", count, d->node_count);
    *out_peers = list;
    *out_count = count;
    return 0;
}

int bt_dht_announce(bt_dht *d, const uint8_t info_hash[20], uint16_t port) {
    if (!d) return -1;
    if (d->token_len <= 0) {
        dlog(d, "DHT announce 缺少 token，先 get_peers");
        return -1;
    }
    dht_node n;
    memset(&n, 0, sizeof(n));
    memcpy(n.ip, d->token_ip, 4);
    n.port = d->token_port;

    bt_be_value a;
    a_dict_init(&a);
    a_dict_add_id(d, &a);
    bt_be_value ih = bt_be_strn(info_hash, 20);
    bt_be_dict_set(&a, "info_hash", &ih);
    bt_be_value p = bt_be_int(port);
    bt_be_dict_set(&a, "port", &p);
    bt_be_value tk = bt_be_strn(d->token, (size_t)d->token_len);
    bt_be_dict_set(&a, "token", &tk);

    bt_be_value r;
    int ok = dht_query(d, &n, "announce_peer", &a, &r);
    if (ok == 0) bt_be_free(&r);
    bt_be_free(&a);
    if (ok == 0) dlog(d, "DHT announce_peer 成功");
    return ok;
}
