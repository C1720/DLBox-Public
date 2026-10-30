#include "bt_tracker.h"
#include "bt_bencode.h"
#include "bt_common.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <errno.h>
#include <fcntl.h>

#define HTTP_TIMEOUT_SEC 12
#define MAX_RESP (4 * 1024 * 1024)

/* ---------- URL 解析 ---------- */
typedef struct {
    char host[256];
    char path[1024];
    uint16_t port;
} parsed_url;

static int parse_url(const char *url, parsed_url *out) {
    memset(out, 0, sizeof(*out));
    if (strncmp(url, "http://", 7) != 0) return -1;
    const char *p = url + 7;
    const char *slash = strchr(p, '/');
    const char *host_end = slash ? slash : p + strlen(p);
    size_t hostlen = (size_t)(host_end - p);
    if (hostlen == 0 || hostlen >= sizeof(out->host)) return -1;
    memcpy(out->host, p, hostlen);
    out->host[hostlen] = '\0';
    out->port = 80;
    char *colon = strchr(out->host, ':');
    if (colon) {
        *colon = '\0';
        out->port = (uint16_t)atoi(colon + 1);
        if (out->port == 0) out->port = 80;
    }
    if (slash) {
        snprintf(out->path, sizeof(out->path), "%s", slash);
    } else {
        out->path[0] = '/';
        out->path[1] = '\0';
    }
    return 0;
}

/* ---------- 百分号编码 ---------- */
const char *bt_peer_addr_str(const bt_peer_addr *a) {
    static char buf[64];
    if (!a) return "?";
    if (a->is_ipv6) {
        inet_ntop(AF_INET6, a->ip, buf, sizeof(buf));
    } else {
        inet_ntop(AF_INET, a->ip, buf, sizeof(buf));
    }
    return buf;
}

void bt_tracker_url_encode(const uint8_t *src, size_t len, char *dst, size_t dstlen) {
    static const char *hx = "0123456789ABCDEF";
    size_t o = 0;
    for (size_t i = 0; i < len; i++) {
        uint8_t c = src[i];
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
            (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~') {
            if (o + 1 < dstlen) dst[o++] = (char)c;
        } else {
            if (o + 3 < dstlen) {
                dst[o++] = '%';
                dst[o++] = hx[c >> 4];
                dst[o++] = hx[c & 0xf];
            }
        }
    }
    if (o < dstlen) dst[o] = '\0';
}

/* ---------- 非阻塞 connect + select 超时 ---------- */
static int connect_timeout(int fd, const struct sockaddr *addr, socklen_t alen, int sec) {
    int fl = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    int r = connect(fd, addr, alen);
    if (r == 0) {
        fcntl(fd, F_SETFL, fl);
        return 0;
    }
    if (errno != EINPROGRESS) return -1;
    fd_set wf, ef;
    FD_ZERO(&wf); FD_ZERO(&ef);
    FD_SET(fd, &wf); FD_SET(fd, &ef);
    struct timeval tv = { sec, 0 };
    r = select(fd + 1, NULL, &wf, &ef, &tv);
    if (r <= 0) return -1;
    int soerr = 0;
    socklen_t sl = sizeof(soerr);
    getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &sl);
    if (soerr != 0) return -1;
    fcntl(fd, F_SETFL, fl);
    return 0;
}

/* ---------- 简单 HTTP GET，返回 body ---------- */
static int http_get(const parsed_url *u, const char *query,
                    uint8_t **out_body, size_t *out_len, char *err, size_t errlen) {
    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    char portstr[8];
    snprintf(portstr, sizeof(portstr), "%u", u->port);
    if (getaddrinfo(u->host, portstr, &hints, &res) != 0 || !res) {
        snprintf(err, errlen, "无法解析 tracker 域名 %s", u->host);
        return -1;
    }
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { freeaddrinfo(res); snprintf(err, errlen, "socket 创建失败"); return -1; }
    bt_set_nosigpipe(fd);
    if (connect_timeout(fd, res->ai_addr, (socklen_t)res->ai_addrlen, HTTP_TIMEOUT_SEC) != 0) {
        freeaddrinfo(res); close(fd); snprintf(err, errlen, "连接 tracker 超时/失败"); return -1;
    }
    freeaddrinfo(res);

    struct timeval rto = { HTTP_TIMEOUT_SEC, 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &rto, sizeof(rto));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &rto, sizeof(rto));

    char req[4096];
    int rl = snprintf(req, sizeof(req),
        "GET %s%s%s HTTP/1.1\r\n"
        "Host: %s\r\n"
        "User-Agent: DLBox/0.2\r\n"
        "Accept: */*\r\n"
        "Accept-Encoding: identity\r\n"
        "Connection: close\r\n\r\n",
        u->path, (strchr(u->path, '?') ? "&" : "?"), query, u->host);
    if (rl <= 0 || (size_t)rl >= sizeof(req)) { close(fd); snprintf(err, errlen, "请求过长"); return -1; }
    if (send(fd, req, (size_t)rl, 0) != rl) {
        close(fd); snprintf(err, errlen, "发送请求失败"); return -1;
    }

    bt_buf buf;
    bt_buf_init(&buf);
    uint8_t tmp[8192];
    ssize_t n;
    while ((n = recv(fd, tmp, sizeof(tmp), 0)) > 0) {
        if (buf.len + (size_t)n > MAX_RESP) break;
        bt_buf_append(&buf, tmp, (size_t)n);
    }
    close(fd);

    if (buf.len == 0) {
        bt_buf_free(&buf);
        snprintf(err, errlen, "tracker 无响应");
        return -1;
    }

    /* 找 \r\n\r\n 分隔头与体 */
    const uint8_t *hdr_end = NULL;
    for (size_t i = 0; i + 3 < buf.len; i++) {
        if (buf.data[i] == '\r' && buf.data[i+1] == '\n' &&
            buf.data[i+2] == '\r' && buf.data[i+3] == '\n') {
            hdr_end = buf.data + i + 4;
            break;
        }
    }
    if (!hdr_end) {
        bt_buf_free(&buf);
        snprintf(err, errlen, "tracker 响应格式异常");
        return -1;
    }
    /* 检查状态码 */
    char status[64];
    snprintf(status, sizeof(status), "%.*s", (int)(hdr_end - buf.data - 4), (char *)buf.data);
    if (!strstr(status, " 200")) {
        bt_buf_free(&buf);
        snprintf(err, errlen, "tracker 返回非 200");
        return -1;
    }
    size_t body_len = buf.len - (size_t)(hdr_end - buf.data);
    uint8_t *body = (uint8_t *)malloc(body_len ? body_len : 1);
    if (!body) { bt_buf_free(&buf); snprintf(err, errlen, "内存不足"); return -1; }
    memcpy(body, hdr_end, body_len);
    bt_buf_free(&buf);
    *out_body = body;
    *out_len = body_len;
    return 0;
}

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
    char *err, size_t errlen)
{
    if (out_peers) *out_peers = NULL;
    if (out_count) *out_count = 0;
    if (out_interval) *out_interval = 1800;
    if (out_seeders) *out_seeders = 0;
    if (out_leechers) *out_leechers = 0;

    parsed_url u;
    if (parse_url(tracker_url, &u) != 0) {
        snprintf(err, errlen, "tracker URL 非法: %s", tracker_url);
        return -1;
    }

    char ih[61], pid[61];
    bt_tracker_url_encode(info_hash, 20, ih, sizeof(ih));
    bt_tracker_url_encode(peer_id, 20, pid, sizeof(pid));

    char query[2048];
    int ql = snprintf(query, sizeof(query),
        "info_hash=%s&peer_id=%s&port=%u&uploaded=%lld&downloaded=%lld&left=%lld&compact=1&no_peer_id=1&numwant=200%s%s",
        ih, pid, local_port,
        (long long)uploaded, (long long)downloaded, (long long)left,
        event ? "&event=" : "", event ? event : "");
    if (ql <= 0 || (size_t)ql >= sizeof(query)) {
        snprintf(err, errlen, "announce 参数过长");
        return -1;
    }

    uint8_t *body = NULL;
    size_t body_len = 0;
    if (http_get(&u, query, &body, &body_len, err, errlen) != 0) {
        return -1;
    }
    int r = bt_tracker_parse_response(body, body_len, out_peers, out_count,
                                      out_interval, out_seeders, out_leechers, err, errlen);
    free(body);
    return r;
}

int bt_tracker_parse_response(const uint8_t *body, size_t body_len,
                              bt_peer_addr **out_peers, int *out_count,
                              int *out_interval, int *out_seeders, int *out_leechers,
                              char *err, size_t errlen)
{
    if (out_peers) *out_peers = NULL;
    if (out_count) *out_count = 0;
    if (out_interval) *out_interval = 1800;
    if (out_seeders) *out_seeders = 0;
    if (out_leechers) *out_leechers = 0;

    bt_be_value resp;
    if (bt_be_decode(body, body_len, &resp) != 0 || resp.type != BT_BE_DICT) {
        snprintf(err, errlen, "tracker 响应不是合法 bencode");
        return -1;
    }

    bt_be_value *failure = bt_be_dict_get(&resp, "failure reason", 15);
    if (failure && failure->type == BT_BE_STR) {
        char *msg = bt_be_strdup(failure);
        snprintf(err, errlen, "tracker 返回错误: %s", msg ? msg : "?");
        free(msg);
        bt_be_free(&resp);
        return -1;
    }

    bt_be_value *iv = bt_be_dict_get(&resp, "interval", 8);
    if (iv && iv->type == BT_BE_INT && iv->as_int > 0 && out_interval)
        *out_interval = (int)iv->as_int;
    bt_be_value *comp = bt_be_dict_get(&resp, "complete", 8);
    if (comp && comp->type == BT_BE_INT && out_seeders) *out_seeders = (int)comp->as_int;
    bt_be_value *incomp = bt_be_dict_get(&resp, "incomplete", 10);
    if (incomp && incomp->type == BT_BE_INT && out_leechers) *out_leechers = (int)incomp->as_int;

    /* 收集 peers（支持 compact IPv4 / 非 compact 字典列表 / compact IPv6） */
    bt_peer_addr *list = NULL;
    int cnt = 0, cap = 0;

#define ADD_PEER(addr_, ipv6_) do { \
        int dup_ = 0; \
        for (int k_ = 0; k_ < cnt; k_++) { \
            if (list[k_].is_ipv6 == (ipv6_) && list[k_].port == (addr_).port && \
                memcmp(list[k_].ip, (addr_).ip, (ipv6_) ? 16 : 4) == 0) { dup_ = 1; break; } \
        } \
        if (dup_) break; \
        if (cnt >= cap) { \
            cap = cap ? cap * 2 : 64; \
            bt_peer_addr *nl_ = (bt_peer_addr *)realloc(list, sizeof(bt_peer_addr) * cap); \
            if (!nl_) { free(list); bt_be_free(&resp); snprintf(err, errlen, "内存不足"); return -1; } \
            list = nl_; \
        } \
        list[cnt++] = (addr_); \
    } while (0)

    bt_be_value *peers = bt_be_dict_get(&resp, "peers", 5);
    if (peers) {
        if (peers->type == BT_BE_STR && peers->as_str.len % 6 == 0) {
            /* compact IPv4 */
            int n = (int)(peers->as_str.len / 6);
            for (int i = 0; i < n; i++) {
                const uint8_t *p = peers->as_str.p + i * 6;
                bt_peer_addr a;
                memset(&a, 0, sizeof(a));
                memcpy(a.ip, p, 4);
                a.port = (uint16_t)((p[4] << 8) | p[5]);
                a.is_ipv6 = 0;
                ADD_PEER(a, 0);
            }
        } else if (peers->type == BT_BE_LIST) {
            /* 非 compact：每个元素是 dict{ip, port}（Ubuntu 等 tracker 用此格式） */
            for (size_t i = 0; i < peers->as_list.count; i++) {
                bt_be_value *it = &peers->as_list.items[i];
                if (it->type != BT_BE_DICT) continue;
                bt_be_value *ipv = bt_be_dict_get(it, "ip", 2);
                bt_be_value *pt = bt_be_dict_get(it, "port", 4);
                if (!ipv || ipv->type != BT_BE_STR || !pt || pt->type != BT_BE_INT) continue;
                char ipbuf[64];
                size_t il = ipv->as_str.len < sizeof(ipbuf) - 1 ? ipv->as_str.len : sizeof(ipbuf) - 1;
                memcpy(ipbuf, ipv->as_str.p, il);
                ipbuf[il] = '\0';
                bt_peer_addr a;
                memset(&a, 0, sizeof(a));
                a.port = (uint16_t)pt->as_int;
                if (inet_pton(AF_INET, ipbuf, a.ip) == 1) {
                    a.is_ipv6 = 0;
                    ADD_PEER(a, 0);
                } else if (inet_pton(AF_INET6, ipbuf, a.ip) == 1) {
                    a.is_ipv6 = 1;
                    ADD_PEER(a, 1);
                }
            }
        }
    }

    /* compact IPv6（peers6，18 字节一组） */
    bt_be_value *peers6 = bt_be_dict_get(&resp, "peers6", 6);
    if (peers6 && peers6->type == BT_BE_STR && peers6->as_str.len % 18 == 0) {
        int n = (int)(peers6->as_str.len / 18);
        for (int i = 0; i < n; i++) {
            const uint8_t *p = peers6->as_str.p + i * 18;
            bt_peer_addr a;
            memset(&a, 0, sizeof(a));
            memcpy(a.ip, p, 16);
            a.port = (uint16_t)((p[16] << 8) | p[17]);
            a.is_ipv6 = 1;
            ADD_PEER(a, 1);
        }
    }

    *out_peers = list;
    *out_count = cnt;

    bt_be_free(&resp);
    return 0;
}
