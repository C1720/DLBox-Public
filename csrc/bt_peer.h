#ifndef BT_PEER_H
#define BT_PEER_H

#include <stdint.h>
#include <stddef.h>
#include <time.h>
#include "bt_common.h"
#include "bt_tracker.h"

#ifdef __cplusplus
extern "C" {
#endif

#define BT_PEER_MAX_REQ 24

typedef enum {
    BT_PEER_TCP_CONNECTING = 0,
    BT_PEER_HANDSHAKE,     /* 已发握手，等对方握手 */
    BT_PEER_ESTABLISHED,   /* 握手完成 */
    BT_PEER_CLOSED,
} bt_peer_state;

typedef struct bt_peer {
    int fd;
    bt_peer_state state;
    bt_peer_addr addr;
    uint8_t peer_id[20];
    uint8_t our_id[20];     /* 我方 peer id（回握手用） */
    uint8_t *bitfield;      /* 对方拥有 piece 的位图，长度 ceil(piece_count/8) */
    uint32_t piece_count;

    int inbound;            /* 1 = 入站连接（对方先发握手） */
    int am_choking;         /* 1 = 我们 choke 对方（P3 恒 0，不做种） */
    int am_interested;      /* 1 = 我们 interested 对方 */
    int peer_choking;       /* 1 = 对方 choke 我们（初始 1） */
    int peer_interested;
    int has_bitfield;       /* 是否收到过对方的 bitfield */

    /* 扩展协议（BEP-10） */
    int ext_handshake_done;
    int peer_ut_metadata_id; /* 对方 ut_metadata 消息 id，-1 不支持 */
    int peer_ut_pex_id;      /* 对方 ut_pex 消息 id，-1 不支持 */
    int metadata_size;       /* 对方扩展握手声明的 metadata 大小，-1 未知 */

    bt_buf inbuf;
    bt_buf outbuf;

    struct { uint32_t index; uint32_t begin; uint32_t length; time_t t; } req[BT_PEER_MAX_REQ];
    int req_count;

    uint64_t downloaded;
    uint64_t uploaded;
    time_t last_recv;
    time_t connected_at;      /* 连接建立时间 */
    time_t last_data_recv;    /* 最近收到 piece 数据的时间（0 = 从未） */
} bt_peer;

/* 引擎回调：处理来自 peer 的事件 */
typedef struct {
    void *ctx;
    void (*on_established)(void *ctx, bt_peer *p);            /* 握手完成 */
    void (*on_bitfield)(void *ctx, bt_peer *p);               /* 收到 bitfield */
    void (*on_have)(void *ctx, bt_peer *p, uint32_t index);
    void (*on_piece)(void *ctx, bt_peer *p, uint32_t index, uint32_t begin,
                     const uint8_t *data, uint32_t len);
    void (*on_choke)(void *ctx, bt_peer *p);
    void (*on_unchoke)(void *ctx, bt_peer *p);
    void (*on_interested)(void *ctx, bt_peer *p);
    void (*on_request)(void *ctx, bt_peer *p, uint32_t index, uint32_t begin, uint32_t length);
    void (*on_ext_handshake)(void *ctx, bt_peer *p);
    void (*on_extended)(void *ctx, bt_peer *p, uint8_t ext_id, const uint8_t *payload, size_t len);
} bt_peer_cb;

void bt_peer_init(bt_peer *p, bt_peer_addr addr, uint32_t piece_count);
void bt_peer_free(bt_peer *p);

/* 发起非阻塞 connect，state 置 BT_PEER_TCP_CONNECTING。返回 0 成功。 */
int bt_peer_connect(bt_peer *p);

/* 接管一个已 accept 的 fd 作为入站 peer（对方先发握手）。返回 0 成功。 */
int bt_peer_accept(bt_peer *p, int fd, bt_peer_addr addr, uint32_t piece_count,
                   const uint8_t our_id[20]);

/* 连接建立完成后调用（校验 SO_ERROR），成功后发握手。返回 0 表示握手已排队。 */
int bt_peer_finish_connect(bt_peer *p, const uint8_t info_hash[20], const uint8_t our_id[20]);

/* 从 socket 读入 inbuf。返回读到的字节数，0=对端关闭，-1=暂时无数据(EAGAIN)。 */
int bt_peer_read(bt_peer *p);

/* 把 outbuf 写出去。返回 1=全部写完，0=还有剩余，-1=错误。 */
int bt_peer_flush(bt_peer *p);

/* 处理 inbuf：握手校验 / 消息解析，触发回调。返回 0 正常，-1 协议错误。 */
int bt_peer_process(bt_peer *p, const uint8_t info_hash[20], const bt_peer_cb *cb);

/* 关闭连接并释放 fd */
void bt_peer_close(bt_peer *p);

/* ---- 消息构造（追加到 outbuf）---- */
void bt_peer_msg_choke(bt_peer *p);
void bt_peer_msg_unchoke(bt_peer *p);
void bt_peer_msg_interested(bt_peer *p);
void bt_peer_msg_not_interested(bt_peer *p);
void bt_peer_msg_have(bt_peer *p, uint32_t index);
void bt_peer_msg_bitfield(bt_peer *p, const uint8_t *bits, uint32_t piece_count);
void bt_peer_msg_request(bt_peer *p, uint32_t index, uint32_t begin, uint32_t length);
void bt_peer_msg_piece(bt_peer *p, uint32_t index, uint32_t begin, const uint8_t *data, uint32_t length);
void bt_peer_msg_cancel(bt_peer *p, uint32_t index, uint32_t begin, uint32_t length);

/* 扩展协议（BEP-10）消息 */
/* metadata_size > 0 时在扩展握手里声明（做种时别的 magnet 客户端据此拉我们的元数据） */
void bt_peer_msg_ext_handshake(bt_peer *p, uint16_t port, int metadata_size);
void bt_peer_msg_extended(bt_peer *p, uint8_t ext_id, const uint8_t *payload, size_t len);

/* 工具：peer 是否拥有某 piece */
int bt_peer_has_piece(const bt_peer *p, uint32_t index);

#ifdef __cplusplus
}
#endif

#endif /* BT_PEER_H */
