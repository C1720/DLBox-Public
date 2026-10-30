#include "bt_peer.h"
#include "bt_bencode.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <netinet/in.h>
#include <arpa/inet.h>

static uint32_t be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static void put_be32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v >> 24);
    p[1] = (uint8_t)(v >> 16);
    p[2] = (uint8_t)(v >> 8);
    p[3] = (uint8_t)v;
}

void bt_peer_init(bt_peer *p, bt_peer_addr addr, uint32_t piece_count) {
    memset(p, 0, sizeof(*p));
    p->fd = -1;
    p->state = BT_PEER_CLOSED;
    p->addr = addr;
    p->piece_count = piece_count;
    p->am_choking = 1;      /* 默认 choke，P3 不需要上传，保持 choke */
    p->peer_choking = 1;    /* 对方默认 choke 我们 */
    p->peer_ut_metadata_id = -1;
    p->peer_ut_pex_id = -1;
    p->metadata_size = -1;
    size_t nb = (piece_count + 7) / 8;
    p->bitfield = (uint8_t *)calloc(nb ? nb : 1, 1);
    bt_buf_init(&p->inbuf);
    bt_buf_init(&p->outbuf);
}

void bt_peer_free(bt_peer *p) {
    if (p->fd >= 0) { close(p->fd); p->fd = -1; }
    free(p->bitfield); p->bitfield = NULL;
    bt_buf_free(&p->inbuf);
    bt_buf_free(&p->outbuf);
}

int bt_peer_connect(bt_peer *p) {
    int fd;
    if (p->addr.is_ipv6) {
        fd = socket(AF_INET6, SOCK_STREAM, 0);
    } else {
        fd = socket(AF_INET, SOCK_STREAM, 0);
    }
    if (fd < 0) return -1;
    bt_set_nosigpipe(fd);
    int fl = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, fl | O_NONBLOCK);

    int r;
    if (p->addr.is_ipv6) {
        struct sockaddr_in6 sa;
        memset(&sa, 0, sizeof(sa));
        sa.sin6_family = AF_INET6;
        sa.sin6_port = htons(p->addr.port);
        memcpy(&sa.sin6_addr, p->addr.ip, 16);
        r = connect(fd, (struct sockaddr *)&sa, sizeof(sa));
    } else {
        struct sockaddr_in sa;
        memset(&sa, 0, sizeof(sa));
        sa.sin_family = AF_INET;
        sa.sin_port = htons(p->addr.port);
        memcpy(&sa.sin_addr.s_addr, p->addr.ip, 4);
        r = connect(fd, (struct sockaddr *)&sa, sizeof(sa));
    }
    if (r != 0 && errno != EINPROGRESS) {
        close(fd);
        return -1;
    }
    p->fd = fd;
    p->state = BT_PEER_TCP_CONNECTING;
    p->last_recv = time(NULL);
    return 0;
}

int bt_peer_finish_connect(bt_peer *p, const uint8_t info_hash[20], const uint8_t our_id[20]) {
    if (p->state != BT_PEER_TCP_CONNECTING || p->fd < 0) return -1;
    int soerr = 0;
    socklen_t sl = sizeof(soerr);
    if (getsockopt(p->fd, SOL_SOCKET, SO_ERROR, &soerr, &sl) != 0 || soerr != 0) {
        bt_peer_close(p);
        return -1;
    }
    memcpy(p->our_id, our_id, 20);
    /* 构造握手并排队 */
    uint8_t hs[68];
    hs[0] = 19;
    memcpy(hs + 1, "BitTorrent protocol", 19);
    memset(hs + 20, 0, 8);          /* reserved */
    hs[20 + 5] |= 0x10;             /* 扩展协议（BEP-10） */
    hs[20 + 7] |= 0x01;             /* DHT（BEP-5） */
    memcpy(hs + 28, info_hash, 20);
    memcpy(hs + 48, our_id, 20);
    bt_buf_append(&p->outbuf, hs, 68);
    p->state = BT_PEER_HANDSHAKE;
    p->connected_at = time(NULL);
    return 0;
}

int bt_peer_accept(bt_peer *p, int fd, bt_peer_addr addr, uint32_t piece_count,
                   const uint8_t our_id[20]) {
    memset(p, 0, sizeof(*p));
    p->fd = fd;
    p->state = BT_PEER_HANDSHAKE;   /* 等对方先发握手 */
    p->addr = addr;
    p->piece_count = piece_count;
    p->inbound = 1;
    p->am_choking = 1;
    p->peer_choking = 1;
    p->peer_ut_metadata_id = -1;
    p->peer_ut_pex_id = -1;
    p->metadata_size = -1;
    memcpy(p->our_id, our_id, 20);
    size_t nb = (piece_count + 7) / 8;
    p->bitfield = (uint8_t *)calloc(nb ? nb : 1, 1);
    bt_buf_init(&p->inbuf);
    bt_buf_init(&p->outbuf);
    bt_set_nosigpipe(fd);
    int fl = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    p->last_recv = time(NULL);
    p->connected_at = time(NULL);
    return 0;
}

int bt_peer_read(bt_peer *p) {
    if (p->fd < 0) return -1;
    /* 一次事件把内核缓冲读干：原来每次只 recv 一次 16KB，40 个 peer 的
     * 吞吐天花板就被「循环轮数 × 16KB」锁死了（这是慢的根因之一）。 */
    uint8_t tmp[32768];
    int total = 0;
    for (int round = 0; round < 8; round++) {
        ssize_t n = recv(p->fd, tmp, sizeof(tmp), 0);
        if (n > 0) {
            if (bt_buf_append(&p->inbuf, tmp, (size_t)n) != 0) return total > 0 ? total : -1;
            total += (int)n;
            continue;
        }
        if (n == 0) return total > 0 ? total : 0;      /* 对端关闭 */
        if (errno == EAGAIN || errno == EWOULDBLOCK) return total > 0 ? total : -1;
        return total > 0 ? total : 0;
    }
    if (total > 0) p->last_recv = time(NULL);
    return total;
}

int bt_peer_flush(bt_peer *p) {
    if (p->fd < 0) return -1;
    if (p->outbuf.len == 0) return 1;
    /* 循环写直到 EAGAIN，把积压一次写干净（一个块请求才 17 字节，
     * 但 have/pex 广播会积压，逐轮写会拖慢整体节奏） */
    for (int round = 0; round < 8 && p->outbuf.len > 0; round++) {
        ssize_t n = send(p->fd, p->outbuf.data, p->outbuf.len, 0);
        if (n > 0) {
            if ((size_t)n == p->outbuf.len) {
                p->outbuf.len = 0;
                return 1;
            }
            memmove(p->outbuf.data, p->outbuf.data + n, p->outbuf.len - (size_t)n);
            p->outbuf.len -= (size_t)n;
            continue;
        }
        if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;
        return -1;
    }
    return p->outbuf.len == 0 ? 1 : 0;
}

int bt_peer_has_piece(const bt_peer *p, uint32_t index) {
    if (!p->bitfield) return 0;
    if (index >= p->piece_count) return 0;
    return (p->bitfield[index / 8] >> (7 - (index % 8))) & 1;
}

static int parse_established(bt_peer *p, const bt_peer_cb *cb) {
    for (;;) {
        if (p->inbuf.len < 4) break;
        uint32_t len = be32(p->inbuf.data);
        if (len == 0) { /* keep-alive */
            memmove(p->inbuf.data, p->inbuf.data + 4, p->inbuf.len - 4);
            p->inbuf.len -= 4;
            continue;
        }
        if (len > (1u << 20)) return -1; /* 异常长度保护 */
        if (p->inbuf.len < 4 + len) break; /* 等更多数据 */
        uint8_t id = p->inbuf.data[4];
        const uint8_t *payload = p->inbuf.data + 5;
        size_t plen = len - 1;

        switch (id) {
            case 0: /* choke */
                p->peer_choking = 1;
                if (cb->on_choke) cb->on_choke(cb->ctx, p);
                break;
            case 1: /* unchoke */
                p->peer_choking = 0;
                if (cb->on_unchoke) cb->on_unchoke(cb->ctx, p);
                break;
            case 2: /* interested */
                p->peer_interested = 1;
                if (cb->on_interested) cb->on_interested(cb->ctx, p);
                break;
            case 3: /* not interested */
                p->peer_interested = 0;
                break;
            case 4: /* have */
                if (plen >= 4) {
                    uint32_t idx = be32(payload);
                    if (idx < p->piece_count) {
                        p->bitfield[idx / 8] |= (uint8_t)(1 << (7 - (idx % 8)));
                        if (cb->on_have) cb->on_have(cb->ctx, p, idx);
                    }
                }
                break;
            case 5: { /* bitfield */
                size_t need = (p->piece_count + 7) / 8;
                size_t n = plen < need ? plen : need;
                memset(p->bitfield, 0, need);
                memcpy(p->bitfield, payload, n);
                p->has_bitfield = 1;
                if (cb->on_bitfield) cb->on_bitfield(cb->ctx, p);
                break;
            }
            case 7: { /* piece */
                if (plen >= 8) {
                    uint32_t idx = be32(payload);
                    uint32_t begin = be32(payload + 4);
                    uint32_t dlen = (uint32_t)(plen - 8);
                    if (cb->on_piece) cb->on_piece(cb->ctx, p, idx, begin, payload + 8, dlen);
                }
                break;
            }
            case 6: { /* request（对方请求我们发数据，做种用） */
                if (plen >= 12) {
                    uint32_t idx = be32(payload);
                    uint32_t begin = be32(payload + 4);
                    uint32_t length = be32(payload + 8);
                    if (cb->on_request) cb->on_request(cb->ctx, p, idx, begin, length);
                }
                break;
            }
            case 20: { /* extended（BEP-10） */
                if (plen >= 1) {
                    uint8_t ext_id = payload[0];
                    const uint8_t *ep = payload + 1;
                    size_t eplen = plen - 1;
                    if (ext_id == 0) {
                        /* 扩展握手 */
                        bt_be_value d;
                        memset(&d, 0, sizeof(d));
                        if (bt_be_decode(ep, eplen, &d) == 0) {
                            if (d.type == BT_BE_DICT) {
                                bt_be_value *m = bt_be_dict_get(&d, "m", 1);
                                if (m && m->type == BT_BE_DICT) {
                                    bt_be_value *um = bt_be_dict_get(m, "ut_metadata", 11);
                                    if (um && um->type == BT_BE_INT)
                                        p->peer_ut_metadata_id = (int)um->as_int;
                                    bt_be_value *up = bt_be_dict_get(m, "ut_pex", 6);
                                    if (up && up->type == BT_BE_INT)
                                        p->peer_ut_pex_id = (int)up->as_int;
                                }
                                /* metadata_size：对方主动告知的元数据大小（libtorrent /
                                 * Transmission / qBittorrent 都会带），有了它就不必先等
                                 * piece 0 回来才知道总长度，可以直接并行拉全部分片 */
                                bt_be_value *ms = bt_be_dict_get(&d, "metadata_size", 13);
                                if (ms && ms->type == BT_BE_INT && ms->as_int > 0)
                                    p->metadata_size = (int)ms->as_int;
                            }
                            bt_be_free(&d);
                        }
                        p->ext_handshake_done = 1;
                        if (cb->on_ext_handshake) cb->on_ext_handshake(cb->ctx, p);
                    } else {
                        if (cb->on_extended) cb->on_extended(cb->ctx, p, ext_id, ep, eplen);
                    }
                }
                break;
            }
            default:
                break; /* 忽略未知消息 */
        }

        size_t total = 4 + len;
        memmove(p->inbuf.data, p->inbuf.data + total, p->inbuf.len - total);
        p->inbuf.len -= total;
    }
    return 0;
}

int bt_peer_process(bt_peer *p, const uint8_t info_hash[20], const bt_peer_cb *cb) {
    if (p->state == BT_PEER_HANDSHAKE) {
        if (p->inbuf.len < 68) return 0;
        uint8_t *h = p->inbuf.data;
        if (h[0] != 19 || memcmp(h + 1, "BitTorrent protocol", 19) != 0) {
            return -1;
        }
        if (memcmp(h + 28, info_hash, 20) != 0) {
            return -1; /* info hash 不符，非本种子 */
        }
        memcpy(p->peer_id, h + 48, 20);
        /* 消费握手 */
        memmove(p->inbuf.data, p->inbuf.data + 68, p->inbuf.len - 68);
        p->inbuf.len -= 68;
        p->state = BT_PEER_ESTABLISHED;
        if (p->inbound) {
            /* 入站：回发我们的握手 */
            uint8_t hs[68];
            hs[0] = 19;
            memcpy(hs + 1, "BitTorrent protocol", 19);
            memset(hs + 20, 0, 8);
            hs[20 + 5] |= 0x10;
            hs[20 + 7] |= 0x01;
            memcpy(hs + 28, info_hash, 20);
            memcpy(hs + 48, p->our_id, 20);
            bt_buf_append(&p->outbuf, hs, 68);
        }
        if (cb->on_established) cb->on_established(cb->ctx, p);
    }
    if (p->state == BT_PEER_ESTABLISHED) {
        return parse_established(p, cb);
    }
    return 0;
}

void bt_peer_close(bt_peer *p) {
    if (p->fd >= 0) { close(p->fd); p->fd = -1; }
    p->state = BT_PEER_CLOSED;
    p->inbuf.len = 0;
    p->outbuf.len = 0;
    p->req_count = 0;
}

/* ---- 消息构造 ---- */

static void append_msg(bt_peer *p, uint8_t id, const uint8_t *payload, uint32_t plen) {
    uint8_t hdr[5];
    put_be32(hdr, plen + 1);
    hdr[4] = id;
    bt_buf_append(&p->outbuf, hdr, 5);
    if (plen) bt_buf_append(&p->outbuf, payload, plen);
}

void bt_peer_msg_choke(bt_peer *p) { append_msg(p, 0, NULL, 0); }
void bt_peer_msg_unchoke(bt_peer *p) { append_msg(p, 1, NULL, 0); }
void bt_peer_msg_interested(bt_peer *p) { append_msg(p, 2, NULL, 0); }
void bt_peer_msg_not_interested(bt_peer *p) { append_msg(p, 3, NULL, 0); }

void bt_peer_msg_have(bt_peer *p, uint32_t index) {
    uint8_t b[4];
    put_be32(b, index);
    append_msg(p, 4, b, 4);
}

void bt_peer_msg_bitfield(bt_peer *p, const uint8_t *bits, uint32_t piece_count) {
    uint32_t nb = (piece_count + 7) / 8;
    append_msg(p, 5, bits, nb);
}

void bt_peer_msg_request(bt_peer *p, uint32_t index, uint32_t begin, uint32_t length) {
    uint8_t b[12];
    put_be32(b, index);
    put_be32(b + 4, begin);
    put_be32(b + 8, length);
    append_msg(p, 6, b, 12);
}

void bt_peer_msg_piece(bt_peer *p, uint32_t index, uint32_t begin, const uint8_t *data, uint32_t length) {
    uint8_t b[8];
    put_be32(b, index);
    put_be32(b + 4, begin);
    /* 先加 5 字节头（4 len + 1 id），再 payload */
    uint8_t hdr[5];
    put_be32(hdr, 8 + length + 1);
    hdr[4] = 7;
    bt_buf_append(&p->outbuf, hdr, 5);
    bt_buf_append(&p->outbuf, b, 8);
    bt_buf_append(&p->outbuf, data, length);
}

void bt_peer_msg_cancel(bt_peer *p, uint32_t index, uint32_t begin, uint32_t length) {
    uint8_t b[12];
    put_be32(b, index);
    put_be32(b + 4, begin);
    put_be32(b + 8, length);
    append_msg(p, 8, b, 12);
}

/* ---- 扩展协议（BEP-10） ---- */

void bt_peer_msg_extended(bt_peer *p, uint8_t ext_id, const uint8_t *payload, size_t len) {
    uint8_t hdr[6];
    put_be32(hdr, (uint32_t)(len + 2));
    hdr[4] = 20;
    hdr[5] = ext_id;
    bt_buf_append(&p->outbuf, hdr, 6);
    if (len) bt_buf_append(&p->outbuf, payload, len);
}

void bt_peer_msg_ext_handshake(bt_peer *p, uint16_t port, int metadata_size) {
    /* 构造 bencode：{ m: { ut_metadata: 1, ut_pex: 2 }, p: port, v: "DLBox 0.3.0" } */
    bt_be_value d;
    memset(&d, 0, sizeof(d));
    d.type = BT_BE_DICT;

    bt_be_value m;
    memset(&m, 0, sizeof(m));
    m.type = BT_BE_DICT;
    bt_be_value um = bt_be_int(1);   /* 本地 ut_metadata id */
    bt_be_dict_set(&m, "ut_metadata", &um);
    bt_be_value up = bt_be_int(2);   /* 本地 ut_pex id */
    bt_be_dict_set(&m, "ut_pex", &up);
    bt_be_dict_set(&d, "m", &m);

    bt_be_value pp = bt_be_int(port);
    bt_be_dict_set(&d, "p", &pp);

    bt_be_value v = bt_be_str("DLBox 0.3.0");
    bt_be_dict_set(&d, "v", &v);

    if (metadata_size > 0) {
        bt_be_value msz = bt_be_int(metadata_size);
        bt_be_dict_set(&d, "metadata_size", &msz);
    }

    size_t len = 0;
    uint8_t *enc = bt_be_encode(&d, &len);
    bt_be_free(&d);
    if (!enc) return;
    bt_peer_msg_extended(p, 0, enc, len);
    free(enc);
}
