#include "bt_engine.h"
#include "bt_common.h"
#include "bt_bencode.h"
#include "bt_tracker.h"
#include "bt_peer.h"
#include "bt_storage.h"
#include "bt_sha1.h"
#include "bt_dht.h"
#include "bt_magnet.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/resource.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <pthread/pthread.h>

#define BT_MAX_PEERS 150
#define BT_BLOCK 16384
#define BT_REQ_TIMEOUT 10         /* 已验证 peer 的块超时 */
#define BT_REQ_TIMEOUT_NEW 6      /* 新 peer 的块超时：快速判定不给数据的僵尸 */
#define BT_IDLE_TIMEOUT 180
#define BT_CONNECT_TIMEOUT 15
#define BT_MAX_KNOWN_PEERS 1024
#define BT_LISTEN_PORT 6881
#define UT_METADATA_ID 1
#define UT_PEX_ID 2
#define UT_METADATA_BLOCK 16384
#define META_REQ_TIMEOUT 8        /* 单片 8 秒没回来就换人重派 */
#define META_PIECE0_PARALLEL 3    /* 大小未知时最多 3 个 peer 同时要 piece 0 */
#define META_PIECE_REPLICAS 2     /* 每片同时最多 2 个副本 */
#define PEX_INTERVAL 60
#define PEX_MAX_PEERS 50
/* P4-fix8：吞吐核心参数。
 * 旧值 12 个 piece × 16 块 = 全局只有 192 个在途块，150 个 peer 平均分到 1.3 块，
 * 等于串行请求 —— 这是速度卡在几百 KB 的根因。 */
#define BT_MAX_ACTIVE_PIECES 48
#define BT_PIPELINE_TRUSTED 24    /* 给过数据的 peer：管道灌满（= BT_PEER_MAX_REQ） */
#define BT_PIPELINE_NEW 1         /* 新 peer：只给 1 块试探，僵尸拿不到更多块 */
#define BT_ZOMBIE_NO_DATA 20      /* 连上 20 秒零字节 → 淘汰 */
#define BT_ZOMBIE_SILENT 60       /* 给过数据后静默 60 秒 → 淘汰（原 90） */
#define BT_SUMMARY_INTERVAL 10    /* 10 秒一行进度摘要，替代每片刷屏 */

/* 并行下载中的 piece（多 piece 并行，充分利用多个 peer 带宽） */
typedef struct {
    int active;
    uint32_t index;
    uint32_t len;
    uint8_t *buf;
    uint8_t *blocks;        /* 0 未请求 / 1 已请求 / 2 已下载 */
    uint8_t *filled;        /* 1 = 该块数据确已写入（用于真实吞吐统计） */
    uint8_t *dup;           /* 该块当前的额外副本数（endgame 加速用） */
    uint32_t block_count;
    uint32_t hint;          /* 空闲块扫描起点：避免每次从 0 号块线性扫 */
} bt_active_piece;

/* 死 peer 黑名单（连了但不给数据的，短时间内不再重连） */
typedef struct {
    bt_peer_addr addr;
    time_t t;
} bt_dead_peer;

static void add_known_peer(bt_engine *e, const bt_peer_addr *a);
static void connect_from_known(bt_engine *e);
static void send_pex(bt_engine *e);

struct bt_engine {
    bt_torrent tor;
    char *save_dir;
    bt_storage st;
    int storage_open;
    uint8_t peer_id[20];
    uint16_t port;
    int64_t uploaded;
    int64_t downloaded;

    bt_engine_log_fn log;
    bt_engine_progress_fn progress;
    void *ctx;
    bt_engine_announce_fn announce;
    void *announce_ctx;

    volatile int stop;
    char error[256];
    char *result_paths;

    bt_peer_cb cb;
    bt_peer peers[BT_MAX_PEERS];
    int peer_count;

    uint8_t *have;
    uint32_t done_pieces;
    uint64_t bytes_written;

    bt_active_piece active[BT_MAX_ACTIVE_PIECES];
    uint32_t next_piece_cursor;
    int assign_cursor;          /* 块分配在 active piece 间的轮转游标 */
    time_t last_summary;        /* 进度摘要上次打印时间 */
    uint64_t summary_bytes;     /* 摘要用字节快照 */

    bt_dead_peer dead_peers[128];
    int dead_count;

    time_t last_progress;
    time_t last_data;
    time_t last_announce;
    time_t last_pex;
    time_t last_dht;
    time_t started;
    int announce_interval;
    uint64_t last_speed_bytes;
    time_t last_speed_time;
    int64_t last_up_speed_bytes;
    time_t last_up_speed_time;

    /* ---- P4：magnet / metadata ---- */
    int magnet_mode;
    int need_metadata;
    bt_buf metadata;            /* 已下载 metadata 字节 */
    int metadata_total;         /* -1 未知 */
    uint8_t *metadata_flags;    /* 每片完成标志 */
    uint8_t *meta_tries;        /* 每片已尝试次数（多的往后排） */
    int metadata_piece_count;
    int metadata_pieces_done;
    int meta_req_piece[BT_MAX_PEERS]; /* 每 peer 在途 metadata piece，-1 无 */
    time_t meta_req_time[BT_MAX_PEERS];

    /* ---- P4：DHT / PEX / 做种 ---- */
    bt_dht *dht;
    /* DHT 查询线程：get_peers 内部是阻塞 select，之前跑在主循环里，
     * 每 45 秒卡 1–2 秒不处理任何 socket（作者说的「周期性卡一下」就是它） */
    pthread_t dht_tid;
    volatile int dht_thread_stop;
    int dht_thread_started;
    pthread_mutex_t dht_mu;
    bt_peer_addr dht_queue[512];
    int dht_qcount;
    uint8_t fetch_hash[20];     /* 线程只读这份，避免与 metadata_to_torrent 的 tor 替换竞争 */
    bt_peer_addr known_peers[BT_MAX_KNOWN_PEERS];
    int known_count;
    int known_cursor;
    int listen_fd;
    int seeding;
};

/* ---------- 深拷贝 torrent ---------- */
static void torrent_copy(bt_torrent *dst, const bt_torrent *src) {
    memset(dst, 0, sizeof(*dst));
    dst->name = bt_strdup(src->name);
    dst->total_length = src->total_length;
    dst->piece_length = src->piece_length;
    dst->piece_count = src->piece_count;
    size_t plen = (size_t)src->piece_count * 20;
    dst->pieces = (uint8_t *)malloc(plen ? plen : 1);
    if (dst->pieces) memcpy(dst->pieces, src->pieces, plen);
    dst->file_count = src->file_count;
    dst->files = (bt_torrent_file *)calloc(src->file_count ? src->file_count : 1,
                                           sizeof(bt_torrent_file));
    for (uint32_t i = 0; i < src->file_count; i++) {
        dst->files[i].path = bt_strdup(src->files[i].path);
        dst->files[i].length = src->files[i].length;
    }
    dst->tracker_count = src->tracker_count;
    dst->trackers = (char **)calloc(src->tracker_count ? src->tracker_count : 1, sizeof(char *));
    for (uint32_t i = 0; i < src->tracker_count; i++) dst->trackers[i] = bt_strdup(src->trackers[i]);
    memcpy(dst->info_hash, src->info_hash, 20);
    memcpy(dst->info_hash_hex, src->info_hash_hex, 41);
    if (src->info_raw && src->info_raw_len > 0) {
        dst->info_raw = (uint8_t *)malloc(src->info_raw_len);
        if (dst->info_raw) {
            memcpy(dst->info_raw, src->info_raw, src->info_raw_len);
            dst->info_raw_len = src->info_raw_len;
        }
    }
}

static void elog(bt_engine *e, const char *fmt, ...) {
    if (!e->log) return;
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    e->log(e->ctx, buf);
}

static void dht_log_cb(void *ctx, const char *line) {
    bt_engine *e = (bt_engine *)ctx;
    elog(e, "[DHT] %s", line);
}

/* ---------- DHT 查询线程 ---------- */
static void *dht_thread_main(void *arg) {
    bt_engine *e = (bt_engine *)arg;
    while (!e->dht_thread_stop) {
        if (e->dht) {
            int want = e->need_metadata ? 80 : 60;
            bt_peer_addr *dl = NULL;
            int dc = 0;
            if (bt_dht_get_peers(e->dht, e->fetch_hash, &dl, &dc, want, 2) == 0 && dc > 0) {
                pthread_mutex_lock(&e->dht_mu);
                for (int i = 0; i < dc && e->dht_qcount < 512; i++)
                    e->dht_queue[e->dht_qcount++] = dl[i];
                pthread_mutex_unlock(&e->dht_mu);
            }
            free(dl);
        }
        for (int s = 0; s < 40 && !e->dht_thread_stop; s++) usleep(200000);  /* ≈8 秒 */
    }
    return NULL;
}

/* 主循环里把线程挖到的 peer 取走 */
static void drain_dht_queue(bt_engine *e) {
    if (!e->dht_thread_started) return;
    bt_peer_addr tmp[32];
    int n = 0;
    pthread_mutex_lock(&e->dht_mu);
    while (n < 32 && e->dht_qcount > 0) tmp[n++] = e->dht_queue[--e->dht_qcount];
    pthread_mutex_unlock(&e->dht_mu);
    for (int i = 0; i < n; i++) add_known_peer(e, &tmp[i]);
    if (n > 0) connect_from_known(e);
}

/* ---------- 位图工具 ---------- */
static void bits_set(uint8_t *bits, uint32_t idx) { bits[idx / 8] |= (uint8_t)(1 << (7 - (idx % 8))); }
static int bits_get(const uint8_t *bits, uint32_t idx) { return (bits[idx / 8] >> (7 - (idx % 8))) & 1; }

/* 本地持有的原始 info 字典（供别人拉 metadata）。有 torrent 元数据就有。 */
static const uint8_t *engine_meta_blob(bt_engine *e, int *out_len) {
    *out_len = 0;
    if (e->tor.info_raw && e->tor.info_raw_len > 0) {
        *out_len = (int)e->tor.info_raw_len;
        return e->tor.info_raw;
    }
    return NULL;
}

/* ---------- 回调转发 ---------- */
static void cb_established(void *ctx, bt_peer *p) {
    bt_engine *e = (bt_engine *)ctx;
    /* 连接细节不逐条打印（50 个 peer 会刷屏），由 gather_peers 打摘要 */
    /* 扩展协议握手（metadata / PEX 都需要）；有原始 info 时一并声明 metadata_size，
     * 别的 magnet 客户端就能直接从我们这里拉元数据 */
    {
        int mlen = 0;
        engine_meta_blob(e, &mlen);
        bt_peer_msg_ext_handshake(p, e->port, mlen > 0 ? mlen : -1);
    }
    if (e->seeding) {
        bt_peer_msg_bitfield(p, e->have, e->tor.piece_count);
        bt_peer_msg_unchoke(p);
        p->am_choking = 0;
    } else if (e->need_metadata) {
        /* metadata 阶段：只下元数据，不发 interested */
    } else {
        bt_peer_msg_interested(p);
        p->am_interested = 1;
    }
}

static void cb_bitfield(void *ctx, bt_peer *p) {
    (void)ctx; (void)p;
    /* bitfield 细节不打印（刷屏） */
}

static void cb_have(void *ctx, bt_peer *p, uint32_t index) {
    bt_engine *e = (bt_engine *)ctx;
    (void)index;
    if (e->need_metadata) return;   /* metadata 阶段不 interested（只要元数据） */
    if (!p->am_interested) {
        bt_peer_msg_interested(p);
        p->am_interested = 1;
    }
}

static void cb_choke(void *ctx, bt_peer *p) {
    bt_engine *e = (bt_engine *)ctx;
    for (int i = 0; i < p->req_count; i++) {
        uint32_t idx = p->req[i].index;
        uint32_t b = p->req[i].begin / BT_BLOCK;
        for (int k = 0; k < BT_MAX_ACTIVE_PIECES; k++) {
            bt_active_piece *ap = &e->active[k];
            if (ap->active && ap->index == idx && b < ap->block_count && ap->blocks[b] == 1) {
                ap->blocks[b] = 0;
                if (ap->dup) ap->dup[b] = 0;
            }
        }
    }
    p->req_count = 0;
}

static void cb_unchoke(void *ctx, bt_peer *p) {
    (void)ctx; (void)p;
    /* 不打印（unchoke 在大量 peer 下刷屏） */
}

static void cb_piece(void *ctx, bt_peer *p, uint32_t index, uint32_t begin,
                     const uint8_t *data, uint32_t len) {
    bt_engine *e = (bt_engine *)ctx;
    p->last_data_recv = time(NULL);

    for (int i = 0; i < p->req_count; i++) {
        if (p->req[i].index == index && p->req[i].begin == begin) {
            memmove(&p->req[i], &p->req[i + 1], sizeof(p->req[0]) * (p->req_count - i - 1));
            p->req_count--;
            break;
        }
    }

    /* 找到对应的 active piece 写入 */
    for (int k = 0; k < BT_MAX_ACTIVE_PIECES; k++) {
        bt_active_piece *ap = &e->active[k];
        if (!ap->active || ap->index != index) continue;
        if ((uint64_t)begin + len <= ap->len) {
            memcpy(ap->buf + begin, data, len);
            uint32_t b0 = begin / BT_BLOCK;
            uint32_t b1 = (uint32_t)(((uint64_t)begin + len + BT_BLOCK - 1) / BT_BLOCK);
            /* filled[] 与 blocks[] 分离：blocks 表示「谁在请求」，filled 表示「数据已到手」。
             * 一个块超时被重派后，原 peer 迟到回包会造成重复数据 ——
             * 只有第一次填充才计入吞吐，否则速度数字会虚高十倍（P4-fix9 实测）。 */
            int fresh = 0;
            for (uint32_t b = b0; b < b1 && b < ap->block_count; b++) {
                if (!ap->filled[b]) {
                    ap->filled[b] = 1;
                    ap->dup[b] = 0;
                    if (b == b0) fresh = 1;
                } else {
                    ap->dup[b] = 0;
                }
                if (ap->blocks[b] == 1) ap->blocks[b] = 2;
            }
            if (fresh) {
                p->downloaded += len;
                e->downloaded += len;
                e->last_data = time(NULL);
            }
        }
        break;
    }
}

static void cb_interested(void *ctx, bt_peer *p) {
    bt_engine *e = (bt_engine *)ctx;
    if (e->seeding && p->am_choking) {
        bt_peer_msg_unchoke(p);
        p->am_choking = 0;
    }
}

/* 对方请求数据（做种） */
static void cb_request(void *ctx, bt_peer *p, uint32_t index, uint32_t begin, uint32_t length) {
    bt_engine *e = (bt_engine *)ctx;
    if (!e->seeding || p->am_choking) return;
    if (index >= e->tor.piece_count) return;
    uint32_t plen = (index == e->tor.piece_count - 1)
        ? (uint32_t)(e->tor.total_length - (uint64_t)index * e->tor.piece_length)
        : e->tor.piece_length;
    if ((uint64_t)begin + length > plen) return;
    if (length > (1u << 17)) return; /* 16KB 正常，防御性上限 128KB */

    uint8_t *buf = (uint8_t *)malloc(length ? length : 1);
    if (!buf) return;
    uint64_t off = (uint64_t)index * e->tor.piece_length + begin;
    if (bt_storage_read_range(&e->st, off, buf, length) != 0) {
        free(buf);
        return;
    }
    bt_peer_msg_piece(p, index, begin, buf, length);
    free(buf);
    p->uploaded += length;
    e->uploaded += length;
    e->last_data = time(NULL);
}

/* ---------- 扩展协议回调 ---------- */
/* 初始化 metadata 接收缓冲（大小已知时调用一次） */
static void metadata_alloc(bt_engine *e, int total) {
    if (total <= 0 || e->metadata_total > 0) return;
    int pieces = (total + UT_METADATA_BLOCK - 1) / UT_METADATA_BLOCK;
    if (pieces <= 0) return;
    uint8_t *nd = (uint8_t *)realloc(e->metadata.data, (size_t)total);
    if (!nd) return;
    e->metadata.data = nd;
    e->metadata.len = (size_t)total;
    e->metadata.cap = (size_t)total;
    memset(e->metadata.data, 0, (size_t)total);
    e->metadata_total = total;
    e->metadata_piece_count = pieces;
    free(e->metadata_flags);
    free(e->meta_tries);
    e->metadata_flags = (uint8_t *)calloc((size_t)pieces, 1);
    e->meta_tries = (uint8_t *)calloc((size_t)pieces, 1);
    e->metadata_pieces_done = 0;
    elog(e, "metadata 总大小 %d 字节，共 %d 片", total, pieces);
}

static void cb_ext_handshake(void *ctx, bt_peer *p) {
    bt_engine *e = (bt_engine *)ctx;
    /* 对方扩展握手声明了 metadata_size 就立刻知道元数据多大，
     * 不必先等 piece 0 回来，直接向所有支持的 peer 并行拉分片 */
    if (e->need_metadata && p->metadata_size > 0 && e->metadata_total <= 0) {
        metadata_alloc(e, p->metadata_size);
    }
}

static void cb_extended(void *ctx, bt_peer *p, uint8_t ext_id, const uint8_t *payload, size_t len) {
    bt_engine *e = (bt_engine *)ctx;
    int idx = (int)(p - e->peers);

    if (ext_id == UT_METADATA_ID) {
        /* ut_metadata 消息（对方发给我们，用本地 id=1） */
        bt_be_value d;
        memset(&d, 0, sizeof(d));
        size_t consumed = 0;
        if (bt_be_decode_prefix(payload, len, &d, &consumed) != 0) return;
        if (d.type == BT_BE_DICT) {
            bt_be_value *mt = bt_be_dict_get(&d, "msg_type", 8);
            bt_be_value *pi = bt_be_dict_get(&d, "piece", 5);
            int mtype = (mt && mt->type == BT_BE_INT) ? (int)mt->as_int : -1;
            int piece = (pi && pi->type == BT_BE_INT) ? (int)pi->as_int : -1;
            if (mtype == 0 && piece >= 0) {
                /* msg_type=0：对方想从我们这里拿 metadata（magnet 客户端互帮互助） */
                int blen = 0;
                const uint8_t *blob = engine_meta_blob(e, &blen);
                if (blob && blen > 0) {
                    size_t off = (size_t)piece * UT_METADATA_BLOCK;
                    if (off < (size_t)blen) {
                        size_t n = (size_t)blen - off;
                        if (n > UT_METADATA_BLOCK) n = UT_METADATA_BLOCK;
                        bt_be_value r;
                        memset(&r, 0, sizeof(r));
                        r.type = BT_BE_DICT;
                        bt_be_value t1 = bt_be_int(1);
                        bt_be_dict_set(&r, "msg_type", &t1);
                        bt_be_value p1 = bt_be_int(piece);
                        bt_be_dict_set(&r, "piece", &p1);
                        bt_be_value tsz = bt_be_int(blen);
                        bt_be_dict_set(&r, "total_size", &tsz);
                        size_t elen = 0;
                        uint8_t *enc = bt_be_encode(&r, &elen);
                        bt_be_free(&r);
                        if (enc) {
                            uint8_t *outb = (uint8_t *)malloc(elen + n);
                            if (outb) {
                                memcpy(outb, enc, elen);
                                memcpy(outb + elen, blob + off, n);
                                bt_peer_msg_extended(p, UT_METADATA_ID, outb, elen + n);
                                free(outb);
                            }
                            free(enc);
                        }
                    }
                }
            } else if (mtype == 1 && piece >= 0) {
                /* msg_type=1：我们请求的分片回来了 */
                if (idx >= 0 && idx < BT_MAX_PEERS) e->meta_req_piece[idx] = -1;
                if (e->metadata_total <= 0) {
                    bt_be_value *ts = bt_be_dict_get(&d, "total_size", 10);
                    if (ts && ts->type == BT_BE_INT) metadata_alloc(e, (int)ts->as_int);
                }
                const uint8_t *data = payload + consumed;
                size_t dlen = len - consumed;
                if (e->metadata_total > 0 && e->metadata_flags &&
                    piece < e->metadata_piece_count && !e->metadata_flags[piece]) {
                    size_t off = (size_t)piece * UT_METADATA_BLOCK;
                    size_t room = (size_t)e->metadata_total - off;
                    size_t n = dlen < room ? dlen : room;
                    memcpy(e->metadata.data + off, data, n);
                    e->metadata_flags[piece] = 1;
                    e->metadata_pieces_done++;
                    elog(e, "metadata piece %d/%d 已收到（%d 字节）",
                         piece + 1, e->metadata_piece_count, (int)n);
                }
            }
        }
        bt_be_free(&d);
    } else if (ext_id == UT_PEX_ID) {
        /* ut_pex 消息 */
        bt_be_value d;
        memset(&d, 0, sizeof(d));
        if (bt_be_decode(payload, len, &d) == 0) {
            if (d.type == BT_BE_DICT) {
                bt_be_value *added = bt_be_dict_get(&d, "added", 5);
                if (added && added->type == BT_BE_STR && added->as_str.len % 6 == 0) {
                    for (size_t i = 0; i + 6 <= added->as_str.len; i += 6) {
                        const uint8_t *q = added->as_str.p + i;
                        bt_peer_addr a;
                        memset(&a, 0, sizeof(a));
                        memcpy(a.ip, q, 4);
                        a.port = (uint16_t)((q[4] << 8) | q[5]);
                        a.is_ipv6 = 0;
                        if (a.port != 0) add_known_peer(e, &a);
                    }
                }
            }
            bt_be_free(&d);
        }
        if (e->known_count > 0) connect_from_known(e);
    }
}

/* ---------- 多 piece 并行：填充 / 校验 / 释放 ---------- */

static int piece_is_active(bt_engine *e, uint32_t idx) {
    for (int k = 0; k < BT_MAX_ACTIVE_PIECES; k++) {
        if (e->active[k].active && e->active[k].index == idx) return 1;
    }
    return 0;
}

/* 填充空闲 active 槽位：从游标位置找未完成且未在下载的 piece */
static void fill_active_pieces(bt_engine *e) {
    for (int k = 0; k < BT_MAX_ACTIVE_PIECES; k++) {
        if (e->active[k].active) continue;
        uint32_t found = 0xffffffff;
        for (uint32_t step = 0; step < e->tor.piece_count; step++) {
            uint32_t i = (e->next_piece_cursor + step) % e->tor.piece_count;
            if (bits_get(e->have, i)) continue;
            if (piece_is_active(e, i)) continue;
            found = i;
            e->next_piece_cursor = (i + 1) % e->tor.piece_count;
            break;
        }
        if (found == 0xffffffff) break;
        bt_active_piece *ap = &e->active[k];
        ap->active = 1;
        ap->index = found;
        ap->hint = 0;
        ap->len = (found == e->tor.piece_count - 1)
            ? (uint32_t)(e->tor.total_length - (uint64_t)found * e->tor.piece_length)
            : e->tor.piece_length;
        ap->buf = (uint8_t *)malloc(ap->len ? ap->len : 1);
        ap->block_count = (ap->len + BT_BLOCK - 1) / BT_BLOCK;
        ap->blocks = (uint8_t *)calloc(ap->block_count ? ap->block_count : 1, 1);
        ap->filled = (uint8_t *)calloc(ap->block_count ? ap->block_count : 1, 1);
        ap->dup = (uint8_t *)calloc(ap->block_count ? ap->block_count : 1, 1);
        if (!ap->buf || !ap->blocks || !ap->filled || !ap->dup) {
            /* 48 片并行 = 约 12MB 缓冲，内存吃紧时安静降级而不是崩 */
            free(ap->buf); ap->buf = NULL;
            free(ap->blocks); ap->blocks = NULL;
            free(ap->filled); ap->filled = NULL;
            free(ap->dup); ap->dup = NULL;
            ap->active = 0;
            continue;
        }
    }
}

/* 检查完成的 active piece：校验 + 写盘 + 释放槽位。返回 -1 表示写盘失败 */
static int check_finish_pieces(bt_engine *e) {
    for (int k = 0; k < BT_MAX_ACTIVE_PIECES; k++) {
        bt_active_piece *ap = &e->active[k];
        if (!ap->active) continue;
        uint32_t done = 0;
        for (uint32_t b = 0; b < ap->block_count; b++) {
            if (ap->filled[b]) done++;
        }
        /* 数据齐了就算完成（不再要求「没有在途请求」，否则重复请求会让整片永远等） */
        if (done != ap->block_count) continue;

        uint8_t digest[20];
        bt_sha1(ap->buf, ap->len, digest);
        if (memcmp(digest, e->tor.pieces + (size_t)ap->index * 20, 20) != 0) {
            elog(e, "piece %u SHA1 校验失败，重下", ap->index);
            for (int i = 0; i < e->peer_count; i++) {
                bt_peer *p = &e->peers[i];
                for (int j = p->req_count - 1; j >= 0; j--) {
                    if (p->req[j].index == ap->index) {
                        memmove(&p->req[j], &p->req[j + 1], sizeof(p->req[0]) * (p->req_count - j - 1));
                        p->req_count--;
                    }
                }
            }
            memset(ap->blocks, 0, ap->block_count);
            continue;
        }
        if (bt_storage_write_piece(&e->st, ap->index, ap->buf, ap->len) != 0) {
            snprintf(e->error, sizeof(e->error), "写盘失败（piece %u）", ap->index);
            return -1;
        }
        bits_set(e->have, ap->index);
        e->done_pieces++;
        e->bytes_written += ap->len;
        /* 每片不再刷屏（18169 片会淹掉日志），改由主循环 10 秒摘要统一报进度 */
        if (e->done_pieces % 50 == 0)
            elog(e, "已落盘 %u/%u 片", e->done_pieces, e->tor.piece_count);
        for (int i = 0; i < e->peer_count; i++) {
            bt_peer *p = &e->peers[i];
            if (p->state == BT_PEER_ESTABLISHED) bt_peer_msg_have(p, ap->index);
        }
        free(ap->buf); ap->buf = NULL;
        free(ap->blocks); ap->blocks = NULL;
        free(ap->filled); ap->filled = NULL;
        free(ap->dup); ap->dup = NULL;
        ap->active = 0;
    }
    return 0;
}

/* 分配请求（P4-fix8 重写）。
 *
 * 旧实现：每轮只给每个 peer 派 1 个块，且全局只有 12 个 active piece（192 个块），
 * 150 个 peer 平均分到 1.3 块 —— 等于串行，速度被 RTT 锁死。
 *
 * 新实现两点：
 *  1. 分级管道：给过数据的 peer 灌满 24 块，新 peer 只给 2 块试探。
 *     僵尸 peer 最多占 2 个块、8 秒就回收，不会像以前那样吞掉一半块再拖 15 秒。
 *  2. 跨 piece 轮转游标：块从不同的 active piece 里取，避免所有 peer 挤同一片。 */
static void assign_requests(bt_engine *e) {
    if (BT_MAX_ACTIVE_PIECES <= 0) return;
    int npieces = BT_MAX_ACTIVE_PIECES;
    if (e->assign_cursor >= npieces) e->assign_cursor = 0;
    time_t now = time(NULL);

    /* 先算每片还缺几块：缺得少的片（<=2）进入 endgame，
     * 允许同一个块同时向 2 个 peer 各要一份，谁先到就用谁的。
     * 这是解「在途 448 块却 0 片落盘」的关键 —— 一两个不给块的 peer
     * 原本能把整片永远卡住。 */
    int miss[BT_MAX_ACTIVE_PIECES];
    for (int k = 0; k < npieces; k++) {
        bt_active_piece *ap = &e->active[k];
        if (!ap->active || !ap->filled) { miss[k] = -1; continue; }
        int m = 0;
        for (uint32_t b = 0; b < ap->block_count; b++) if (!ap->filled[b]) m++;
        miss[k] = m;
    }

    for (int i = 0; i < e->peer_count; i++) {
        bt_peer *p = &e->peers[i];
        if (p->state != BT_PEER_ESTABLISHED) continue;
        if (p->peer_choking || !p->am_interested) continue;

        int want;
        if (p->downloaded == 0) {
            want = BT_PIPELINE_NEW;                 /* 没给过数据：只试探 2 块 */
        } else if (p->last_data_recv > 0 && now - p->last_data_recv > 5) {
            want = 4;                               /* 给过数据但最近 5 秒静默：降档 */
        } else {
            want = BT_PIPELINE_TRUSTED;             /* 活跃做种者：灌满 */
        }
        if (want > BT_PEER_MAX_REQ) want = BT_PEER_MAX_REQ;

        while (p->req_count < want) {
            int found = 0;
            uint32_t pidx = 0, begin = 0, len = 0;
            for (int k = 0; k < npieces && !found; k++) {
                int kk = (e->assign_cursor + k) % npieces;
                bt_active_piece *ap = &e->active[kk];
                if (!ap->active) continue;
                if (p->has_bitfield && !bt_peer_has_piece(p, ap->index)) continue;
                /* 从 hint 起环形扫：150 peer × 24 块管道每轮都要找空块，
                 * 线性扫 48×16 会产生每秒千万级的无效比较，白白烧 CPU */
                uint32_t bc = ap->block_count;
                uint32_t h = (ap->hint < bc) ? ap->hint : 0;
                int endgame = (miss[kk] > 0 && miss[kk] <= 2);
                for (uint32_t i2 = 0; i2 < bc; i2++) {
                    uint32_t b = h + i2;
                    if (b >= bc) b -= bc;
                    int take = 0;
                    if (ap->blocks[b] == 0) {
                        take = 1;
                    } else if (endgame && ap->blocks[b] == 1 && ap->dup[b] < 2) {
                        take = 2;   /* endgame 复制一份请求 */
                    }
                    if (take) {
                        pidx = ap->index;
                        begin = b * BT_BLOCK;
                        len = ap->len - begin;
                        if (len > BT_BLOCK) len = BT_BLOCK;
                        if (take == 1) ap->blocks[b] = 1;
                        else ap->dup[b]++;
                        ap->hint = (b + 1 >= bc) ? 0 : (b + 1);
                        found = 1;
                        break;
                    }
                }
            }
            if (!found) break;
            e->assign_cursor = (e->assign_cursor + 1) % npieces;
            bt_peer_msg_request(p, pidx, begin, len);
            p->req[p->req_count].index = pidx;
            p->req[p->req_count].begin = begin;
            p->req[p->req_count].length = len;
            p->req[p->req_count].t = time(NULL);
            p->req_count++;
        }
    }
}

static void retry_timeouts(bt_engine *e) {
    time_t now = time(NULL);
    for (int i = 0; i < e->peer_count; i++) {
        bt_peer *p = &e->peers[i];
        for (int j = p->req_count - 1; j >= 0; j--) {
            int to = (p->downloaded > 0) ? BT_REQ_TIMEOUT : BT_REQ_TIMEOUT_NEW;
            if (now - p->req[j].t > to) {
                /* 超时先发 cancel：否则原 peer 迟到的回包会变成重复数据，
                 * 白吃带宽还让速度数字虚高（实测虚高 10 倍以上） */
                bt_peer_msg_cancel(p, p->req[j].index, p->req[j].begin, p->req[j].length);
                uint32_t idx = p->req[j].index;
                uint32_t b = p->req[j].begin / BT_BLOCK;
                for (int k = 0; k < BT_MAX_ACTIVE_PIECES; k++) {
                    bt_active_piece *ap = &e->active[k];
                    if (ap->active && ap->index == idx && b < ap->block_count && ap->blocks[b] == 1) {
                        ap->blocks[b] = 0;
                        if (ap->dup) ap->dup[b] = 0;
                    }
                }
                memmove(&p->req[j], &p->req[j + 1], sizeof(p->req[0]) * (p->req_count - j - 1));
                p->req_count--;
            }
        }
    }
}

/* ---------- announce 并收集 peers ---------- */
static int announce_all(bt_engine *e, const char *event, bt_peer_addr **out, int *out_count) {
    bt_peer_addr *all = NULL;
    int n = 0, cap = 0;
    int64_t left = (int64_t)(e->tor.total_length - e->bytes_written);
    if (left < 0) left = 0;

    for (uint32_t ti = 0; ti < e->tor.tracker_count; ti++) {
        bt_peer_addr *pl = NULL;
        int pc = 0, interval = 0, seeders = 0, leechers = 0;
        char err[256] = {0};
        int r;
        if (e->announce) {
            r = e->announce(e->announce_ctx, e->tor.trackers[ti], e->tor.info_hash, e->peer_id,
                            e->port, e->uploaded, e->downloaded, left, event,
                            &pl, &pc, &interval, &seeders, &leechers, err, sizeof(err));
        } else {
            r = bt_tracker_announce(e->tor.trackers[ti], e->tor.info_hash, e->peer_id,
                                    e->port, e->uploaded, e->downloaded, left, event,
                                    &pl, &pc, &interval, &seeders, &leechers, err, sizeof(err));
        }
        if (r != 0) {
            elog(e, "tracker %s 失败: %s", e->tor.trackers[ti], err);
            continue;
        }
        if (interval > 0) e->announce_interval = interval;
        elog(e, "tracker %s 返回 %d 个 peer（种子 %d / 下载中 %d）",
             e->tor.trackers[ti], pc, seeders, leechers);
        for (int i = 0; i < pc; i++) {
            int dup = 0;
            int plen = pl[i].is_ipv6 ? 16 : 4;
            for (int j = 0; j < n; j++) {
                if (all[j].is_ipv6 == pl[i].is_ipv6 && all[j].port == pl[i].port &&
                    memcmp(all[j].ip, pl[i].ip, plen) == 0) { dup = 1; break; }
            }
            if (dup) continue;
            if (n >= cap) {
                cap = cap ? cap * 2 : 64;
                bt_peer_addr *na = (bt_peer_addr *)realloc(all, sizeof(bt_peer_addr) * cap);
                if (!na) { free(pl); free(all); return -1; }
                all = na;
            }
            all[n++] = pl[i];
        }
        free(pl);
    }
    *out = all;
    *out_count = n;
    return 0;
}

/* ---------- known peers 池 ---------- */
static void add_known_peer(bt_engine *e, const bt_peer_addr *a) {
    if (!a || a->port == 0) return;
    int alen = a->is_ipv6 ? 16 : 4;
    for (int i = 0; i < e->known_count; i++) {
        if (e->known_peers[i].is_ipv6 == a->is_ipv6 &&
            e->known_peers[i].port == a->port &&
            memcmp(e->known_peers[i].ip, a->ip, alen) == 0)
            return;
    }
    if (e->known_count < BT_MAX_KNOWN_PEERS) {
        e->known_peers[e->known_count++] = *a;
    }
}

static int count_active(bt_engine *e) {
    int n = 0;
    for (int i = 0; i < e->peer_count; i++) {
        if (e->peers[i].state == BT_PEER_ESTABLISHED ||
            e->peers[i].state == BT_PEER_HANDSHAKE ||
            e->peers[i].state == BT_PEER_TCP_CONNECTING) n++;
    }
    return n;
}

static int peer_addr_equal(const bt_peer_addr *a, const bt_peer_addr *b) {
    if (a->is_ipv6 != b->is_ipv6 || a->port != b->port) return 0;
    return memcmp(a->ip, b->ip, a->is_ipv6 ? 16 : 4) == 0;
}

/* 是否已有该地址的活跃连接（CONNECTING/HANDSHAKE/ESTABLISHED） */
static int peer_connected(bt_engine *e, const bt_peer_addr *a) {
    for (int i = 0; i < e->peer_count; i++) {
        bt_peer *p = &e->peers[i];
        if (p->state == BT_PEER_CLOSED) continue;
        if (peer_addr_equal(&p->addr, a)) return 1;
    }
    return 0;
}

static void add_dead_peer(bt_engine *e, const bt_peer_addr *a) {
    time_t now = time(NULL);
    for (int i = 0; i < e->dead_count; i++) {
        if (peer_addr_equal(&e->dead_peers[i].addr, a)) {
            e->dead_peers[i].t = now;
            return;
        }
    }
    int slot;
    if (e->dead_count < 128) {
        slot = e->dead_count++;
    } else {
        slot = 0;
        for (int i = 1; i < e->dead_count; i++)
            if (e->dead_peers[i].t < e->dead_peers[slot].t) slot = i;
    }
    e->dead_peers[slot].addr = *a;
    e->dead_peers[slot].t = now;
}

/* 黑名单内（10 分钟内不给数据过的）→ 不再连接 */
static int is_dead_peer(bt_engine *e, const bt_peer_addr *a) {
    time_t now = time(NULL);
    for (int i = 0; i < e->dead_count; i++) {
        if (peer_addr_equal(&e->dead_peers[i].addr, a)) {
            if (now - e->dead_peers[i].t < 600) return 1;
            e->dead_peers[i] = e->dead_peers[e->dead_count - 1];
            e->dead_count--;
            return 0;
        }
    }
    return 0;
}

/* 淘汰「连上但不给数据」的 peer，给真做种者腾位置 */
static void drop_dead_peers(bt_engine *e) {
    if (e->seeding) return;
    time_t now = time(NULL);
    int dropped = 0;
    for (int i = 0; i < e->peer_count; i++) {
        bt_peer *p = &e->peers[i];
        if (p->state != BT_PEER_ESTABLISHED) continue;
        if (p->connected_at == 0) { p->connected_at = now; continue; }
        if (p->last_data_recv == 0 && now - p->connected_at > BT_ZOMBIE_NO_DATA) {
            add_dead_peer(e, &p->addr);
            bt_peer_close(p);
            dropped++;
        } else if (p->last_data_recv > 0 && now - p->last_data_recv > BT_ZOMBIE_SILENT) {
            add_dead_peer(e, &p->addr);
            bt_peer_close(p);
            dropped++;
        }
    }
    if (dropped) elog(e, "淘汰 %d 个不给数据的 peer（活跃 %d）", dropped, count_active(e));
}

static void connect_from_known(bt_engine *e) {
    int connected = 0;
    int total = e->known_count;
    if (total <= 0) return;
    if (e->known_cursor >= total) e->known_cursor = 0;
    int tried = 0;
    int stop = 0;
    int base = e->known_cursor;

    /* 两趟：先 IPv4 再 IPv6。国内连海外 IPv6 常常半死不活（假做种重灾区），
     * 先让 IPv4 占满槽位，IPv6 只做补充。 */
    int v6_total = 0;
    for (int i = 0; i < e->peer_count; i++)
        if (e->peers[i].state != BT_PEER_CLOSED && e->peers[i].addr.is_ipv6) v6_total++;
    for (int pass = 0; pass < 2 && !stop; pass++) {
        int want_v6 = pass;
        for (int k = 0; k < total; k++) {
            if (count_active(e) >= BT_MAX_PEERS) { stop = 1; break; }
            if (connected >= 20) { stop = 1; break; }   /* 每轮最多补 20 条，避免连接风暴 */
            /* 海外 IPv6 假做种多、链路差，最多占 40 条，把槽位留给 IPv4 */
            if (want_v6 && v6_total >= 40) { stop = 1; break; }
            int i = (base + k) % total;   /* 环形遍历：避免每次都从 0 号开始重复试同一批死地址 */
            if (e->known_peers[i].is_ipv6 != want_v6) continue;
            if (peer_connected(e, &e->known_peers[i])) continue; /* 已有连接，去重 */
            if (is_dead_peer(e, &e->known_peers[i])) continue;   /* 黑名单内不重连 */
            /* 找空槽位 */
            int slot = -1;
            for (int j = 0; j < e->peer_count; j++) {
                if (e->peers[j].state == BT_PEER_CLOSED) { slot = j; break; }
            }
            if (slot < 0) { stop = 1; break; }
            bt_peer_free(&e->peers[slot]);
            bt_peer_init(&e->peers[slot], e->known_peers[i], e->tor.piece_count);
            if (bt_peer_connect(&e->peers[slot]) != 0) {
                bt_peer_free(&e->peers[slot]);
                e->peers[slot].state = BT_PEER_CLOSED;
                add_dead_peer(e, &e->known_peers[i]);   /* 连不上的别反复试 */
                tried++;
                continue;
            }
            tried++;
            connected++;
            if (want_v6) v6_total++;
        }
    }
    e->known_cursor = (base + tried + 1) % total;
    if (connected >= 5) elog(e, "发起 %d 个新连接（当前活跃 %d，已知 %d）",
                             connected, count_active(e), e->known_count);
}

/* ---------- 收拢 peers：tracker + DHT ---------- */
static void gather_peers(bt_engine *e, const char *event) {
    bt_peer_addr *tl = NULL;
    int tc = 0;
    if (e->tor.tracker_count > 0) {
        announce_all(e, event, &tl, &tc);
        for (int i = 0; i < tc; i++) {
            add_known_peer(e, &tl[i]);
            /* 关键：把 tracker 给的地址当 DHT 入口。国内 6 个公共 bootstrap
             * 节点经常全被墙，只有用真实 peer 当入口，路由表才能从 1 个长到几十个 */
            if (e->dht && !tl[i].is_ipv6) bt_dht_add_node(e->dht, &tl[i]);
        }
        free(tl);
    } else {
        elog(e, "无 tracker，依赖 DHT 发现 peer");
    }

    /* DHT 由后台线程查（drain_dht_queue 取结果），这里不再同步阻塞 */
    if (e->seeding && e->dht && time(NULL) - e->last_dht >= 120) {
        bt_dht_announce(e->dht, e->tor.info_hash, e->port);
        e->last_dht = time(NULL);
    }
    /* 做种时只宣告 + 监听入站，不主动连 50 个做种者（避免刷屏与无意义连接） */
    if (!e->seeding) connect_from_known(e);
}

/* ---------- 完成标记：区分「真的下载完」与「ftruncate 预分配的空洞文件」 ---------- */
static void complete_marker_path(bt_engine *e, char *out, size_t outlen) {
    snprintf(out, outlen, "%s/.dlbox-%s.complete", e->save_dir, e->tor.info_hash_hex);
}

static void write_complete_marker(bt_engine *e) {
    char path[1024];
    complete_marker_path(e, path, sizeof(path));
    FILE *f = fopen(path, "w");
    if (f) {
        fprintf(f, "%llu\n", (unsigned long long)e->tor.total_length);
        fclose(f);
    }
}

static int check_complete_marker(bt_engine *e) {
    char path[1024];
    complete_marker_path(e, path, sizeof(path));
    struct stat sb;
    if (stat(path, &sb) != 0) return 0; /* 无标记 → 视为未完整 */
    return 1;
}

/* ---------- 做种：监听 ---------- */
static int start_listen(bt_engine *e) {
    if (e->listen_fd >= 0) return 0;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    bt_set_nosigpipe(fd);
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_addr.s_addr = INADDR_ANY;
    sa.sin_port = htons(e->port);
    if (bind(fd, (struct sockaddr *)&sa, sizeof(sa)) != 0) {
        close(fd);
        elog(e, "监听端口 %u 失败（可能被占用）", e->port);
        return -1;
    }
    if (listen(fd, 16) != 0) { close(fd); return -1; }
    int fl = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    e->listen_fd = fd;
    elog(e, "已开始监听端口 %u（做种）", e->port);
    return 0;
}

static void accept_peer(bt_engine *e) {
    struct sockaddr_in sa;
    socklen_t sl = sizeof(sa);
    int fd = accept(e->listen_fd, (struct sockaddr *)&sa, &sl);
    if (fd < 0) return;
    for (int i = 0; i < e->peer_count; i++) {
        if (e->peers[i].state == BT_PEER_CLOSED) {
            bt_peer_addr addr;
            memset(&addr, 0, sizeof(addr));
            memcpy(addr.ip, &sa.sin_addr.s_addr, 4);
            addr.port = ntohs(sa.sin_port);
            addr.is_ipv6 = 0;
            bt_peer_free(&e->peers[i]);
            bt_peer_accept(&e->peers[i], fd, addr, e->tor.piece_count, e->peer_id);
            return;
        }
    }
    close(fd);
}

/* ---------- peers 服务（select 一次 + 处理） ---------- */
static void service_peers(bt_engine *e, int include_listen, int timeout_ms) {
    fd_set rf, wf;
    FD_ZERO(&rf); FD_ZERO(&wf);
    int maxfd = -1;
    if (include_listen && e->listen_fd >= 0) {
        FD_SET(e->listen_fd, &rf);
        maxfd = e->listen_fd;
    }
    for (int i = 0; i < e->peer_count; i++) {
        bt_peer *p = &e->peers[i];
        if (p->fd < 0 || p->state == BT_PEER_CLOSED) continue;
        FD_SET(p->fd, &rf);
        if (p->state == BT_PEER_TCP_CONNECTING || p->outbuf.len > 0) FD_SET(p->fd, &wf);
        if (p->fd > maxfd) maxfd = p->fd;
    }

    struct timeval tv;
    tv.tv_sec = timeout_ms / 1000;
    tv.tv_usec = (timeout_ms % 1000) * 1000;
    int sr = select(maxfd + 1, &rf, &wf, NULL, &tv);
    time_t now = time(NULL);

    if (sr <= 0) {
        for (int i = 0; i < e->peer_count; i++) {
            bt_peer *p = &e->peers[i];
            if (p->state == BT_PEER_TCP_CONNECTING && now - p->last_recv > BT_CONNECT_TIMEOUT)
                bt_peer_close(p);
        }
        return;
    }

    if (include_listen && e->listen_fd >= 0 && FD_ISSET(e->listen_fd, &rf)) {
        accept_peer(e);
    }

    for (int i = 0; i < e->peer_count; i++) {
        bt_peer *p = &e->peers[i];
        if (p->fd < 0 || p->state == BT_PEER_CLOSED) continue;
        int fd = p->fd;

        if (FD_ISSET(fd, &wf)) {
            if (p->state == BT_PEER_TCP_CONNECTING) {
                if (bt_peer_finish_connect(p, e->tor.info_hash, e->peer_id) != 0) {
                    bt_peer_close(p);
                    continue;
                }
            } else {
                if (bt_peer_flush(p) < 0) {
                    bt_peer_close(p);
                    continue;
                }
            }
        }
        if (FD_ISSET(fd, &rf)) {
            int r = bt_peer_read(p);
            if (r == 0) { bt_peer_close(p); continue; }
            if (r > 0) {
                if (bt_peer_process(p, e->tor.info_hash, &e->cb) != 0) {
                    bt_peer_close(p);
                }
            }
        }
        if (p->state == BT_PEER_TCP_CONNECTING && now - p->last_recv > BT_CONNECT_TIMEOUT) {
            bt_peer_close(p);
        }
    }
}

/* ---------- metadata 下载 ---------- */
static void metadata_send_request(bt_engine *e, bt_peer *p, int piece) {
    bt_be_value d;
    memset(&d, 0, sizeof(d));
    d.type = BT_BE_DICT;
    bt_be_value mt = bt_be_int(0);
    bt_be_dict_set(&d, "msg_type", &mt);
    bt_be_value pi = bt_be_int(piece);
    bt_be_dict_set(&d, "piece", &pi);
    size_t len = 0;
    uint8_t *enc = bt_be_encode(&d, &len);
    bt_be_free(&d);
    if (!enc) return;
    bt_peer_msg_extended(p, p->peer_ut_metadata_id, enc, len);
    free(enc);
}

/* 某分片当前有几个 peer 在要 */
static int meta_piece_inflight(bt_engine *e, int piece) {
    int n = 0;
    for (int i = 0; i < e->peer_count; i++)
        if (e->meta_req_piece[i] == piece) n++;
    return n;
}

/* 派发 metadata 分片：多 peer 并行 + 超时换人 + 每片多副本
 * P4-fix7 核心修复：旧实现「piece 0 只派给唯一一个 peer 且永不超时复位」，
 * 一旦那个 peer 是假做种就整盘卡死 5 分钟，一片都拿不到。 */
static void request_metadata_pieces(bt_engine *e) {
    if (!e->need_metadata) return;
    time_t now = time(NULL);

    /* 1) 超时释放：请求发出 8 秒还没回来，认为这个 peer 不给，重新派人 */
    for (int i = 0; i < e->peer_count; i++) {
        if (e->meta_req_piece[i] < 0) continue;
        bt_peer *p = &e->peers[i];
        if (p->state != BT_PEER_ESTABLISHED) { e->meta_req_piece[i] = -1; continue; }
        if (now - e->meta_req_time[i] >= META_REQ_TIMEOUT) e->meta_req_piece[i] = -1;
    }

    /* 2) 分配：每个支持 ut_metadata 的 peer 一次压 1 片 */
    for (int i = 0; i < e->peer_count; i++) {
        bt_peer *p = &e->peers[i];
        if (p->state != BT_PEER_ESTABLISHED) continue;
        if (p->peer_ut_metadata_id < 0) continue;
        if (e->meta_req_piece[i] >= 0) continue;

        int piece = -1;
        if (e->metadata_total <= 0) {
            /* 大小还不知道：任何一片 data 都会带回 total_size，
             * 允许最多 3 个 peer 同时要 piece 0，谁快用谁 */
            if (meta_piece_inflight(e, 0) >= META_PIECE0_PARALLEL) continue;
            piece = 0;
        } else {
            if (!e->metadata_flags || !e->meta_tries) break;
            int best = -1, best_score = 1 << 30;
            for (int j = 0; j < e->metadata_piece_count; j++) {
                if (e->metadata_flags[j]) continue;
                int inflight = meta_piece_inflight(e, j);
                if (inflight >= META_PIECE_REPLICAS) continue;
                int score = inflight * 1000 + (e->meta_tries ? e->meta_tries[j] : 0) * 10 + j;
                if (score < best_score) { best_score = score; best = j; }
            }
            piece = best;
            if (piece < 0) continue;
        }
        if (e->meta_tries && piece < e->metadata_piece_count && e->meta_tries[piece] < 250)
            e->meta_tries[piece]++;
        metadata_send_request(e, p, piece);
        e->meta_req_piece[i] = piece;
        e->meta_req_time[i] = now;
    }
}

static int metadata_download(bt_engine *e) {
    e->metadata_total = -1;
    e->metadata_pieces_done = 0;
    e->metadata_piece_count = 0;
    free(e->metadata_flags); e->metadata_flags = NULL;
    free(e->meta_tries); e->meta_tries = NULL;
    bt_buf_init(&e->metadata);
    for (int i = 0; i < BT_MAX_PEERS; i++) { e->meta_req_piece[i] = -1; e->meta_req_time[i] = 0; }

    elog(e, "开始下载 metadata（info_hash %s）", e->tor.info_hash_hex);

    /* tracker 先打一轮（顺便把 tracker 给的地址当 DHT 入口） */
    gather_peers(e, "started");

    time_t started_meta = time(NULL);
    time_t last_log = 0;

    while (!e->stop) {
        time_t now = time(NULL);
        service_peers(e, 0, 400);
        request_metadata_pieces(e);

        /* 元数据阶段持续用 DHT 挖 peer（线程在后台查，这里只取结果） */
        drain_dht_queue(e);

        /* 元数据阶段也做 PEX（连上的 peer 互相交换，能快速扩 peer 池） */
        if (now - e->last_pex >= 30) {
            send_pex(e);
            e->last_pex = now;
        }

        /* 元数据阶段上报（total 未知，报 peer 数） */
        if (now - e->last_progress >= 2) {
            e->last_progress = now;
            if (e->progress) e->progress(e->ctx, 0, 0, count_active(e), 0);
        }

        /* 每 4 秒打一行进度，方便 作者判断 metadata 到底卡在哪 */
        if (now - last_log >= 4) {
            last_log = now;
            int ut = 0;
            for (int i = 0; i < e->peer_count; i++)
                if (e->peers[i].state == BT_PEER_ESTABLISHED && e->peers[i].peer_ut_metadata_id >= 0) ut++;
            if (e->metadata_total > 0)
                elog(e, "metadata 进度 %d/%d 片 · 可提供源 %d 个 · 活跃 peer %d",
                     e->metadata_pieces_done, e->metadata_piece_count, ut, count_active(e));
            else
                elog(e, "metadata 等待元数据大小 · 可提供源 %d 个 · 活跃 peer %d · 已知 peer %d",
                     ut, count_active(e), e->known_count);
        }

        /* 完成检查 */
        if (e->metadata_piece_count > 0 && e->metadata_pieces_done == e->metadata_piece_count) {
            uint8_t digest[20];
            bt_sha1(e->metadata.data, (size_t)e->metadata_total, digest);
            if (memcmp(digest, e->tor.info_hash, 20) == 0) {
                elog(e, "metadata 下载完成（%d 字节），SHA1 校验通过", e->metadata_total);
                return 0;
            }
            elog(e, "metadata SHA1 校验失败，重新下载");
            e->metadata_total = -1;
            e->metadata_pieces_done = 0;
            e->metadata_piece_count = 0;
            free(e->metadata_flags); e->metadata_flags = NULL;
            free(e->meta_tries); e->meta_tries = NULL;
            for (int i = 0; i < BT_MAX_PEERS; i++) e->meta_req_piece[i] = -1;
        }

        if (now - started_meta > 300) {
            snprintf(e->error, sizeof(e->error), "metadata 下载超时（5 分钟）");
            elog(e, "错误: %s", e->error);
            return -1;
        }
    }
    return 2;
}

/* metadata → 完整 torrent */
static int metadata_to_torrent(bt_engine *e) {
    /* 构造 "d4:info" + metadata + "e"，喂给 torrent 解析 */
    bt_buf tb;
    bt_buf_init(&tb);
    bt_buf_append(&tb, "d4:info", 7);
    bt_buf_append(&tb, e->metadata.data, (size_t)e->metadata_total);
    bt_buf_append(&tb, "e", 1);

    bt_torrent ntor;
    char perr[256] = {0};
    if (bt_torrent_parse(tb.data, tb.len, &ntor, perr, sizeof(perr)) != 0) {
        bt_buf_free(&tb);
        snprintf(e->error, sizeof(e->error), "metadata 解析失败: %s", perr);
        return -1;
    }
    bt_buf_free(&tb);

    /* 校验 info hash */
    if (memcmp(ntor.info_hash, e->tor.info_hash, 20) != 0) {
        bt_torrent_free(&ntor);
        snprintf(e->error, sizeof(e->error), "metadata info hash 与 magnet 不符");
        return -1;
    }

    /* 替换 e->tor（保留 magnet 带来的 tracker） */
    bt_torrent old = e->tor;
    e->tor = ntor;
    /* 把 magnet 的 tracker 合并进去 */
    for (uint32_t i = 0; i < old.tracker_count; i++) {
        int dup = 0;
        for (uint32_t j = 0; j < e->tor.tracker_count; j++) {
            if (strcmp(old.trackers[i], e->tor.trackers[j]) == 0) { dup = 1; break; }
        }
        if (!dup) {
            char **nl = (char **)realloc(e->tor.trackers, sizeof(char *) * (e->tor.tracker_count + 1));
            if (nl) {
                e->tor.trackers = nl;
                e->tor.trackers[e->tor.tracker_count] = bt_strdup(old.trackers[i]);
                e->tor.tracker_count++;
            }
        }
    }
    bt_torrent_free(&old);

    elog(e, "metadata 解析成功：%s（%llu 字节，%u 片）",
         e->tor.name ? e->tor.name : "?", (unsigned long long)e->tor.total_length, e->tor.piece_count);

    /* 关闭所有 peer（它们的 piece_count 还是 0，重新连接） */
    for (int i = 0; i < e->peer_count; i++) {
        bt_peer_free(&e->peers[i]);
        e->peers[i].state = BT_PEER_CLOSED;
    }
    free(e->metadata_flags); e->metadata_flags = NULL;
    free(e->metadata.data); e->metadata.data = NULL;
    return 0;
}

/* ---------- PEX 发送 ---------- */
static void send_pex(bt_engine *e) {
    if (e->known_count == 0) return;
    for (int i = 0; i < e->peer_count; i++) {
        bt_peer *p = &e->peers[i];
        if (p->state != BT_PEER_ESTABLISHED) continue;
        if (p->peer_ut_pex_id < 0) continue;

        /* 收集除该 peer 外的 known peers（最多 PEX_MAX_PEERS） */
        bt_buf added;
        bt_buf_init(&added);
        bt_buf flags;
        bt_buf_init(&flags);
        int n = 0;
        for (int k = 0; k < e->known_count && n < PEX_MAX_PEERS; k++) {
            bt_peer_addr *a = &e->known_peers[k];
            if (a->is_ipv6) continue; /* BEP-11 的 added6 暂不实现 */
            if (a->port == p->addr.port && !p->addr.is_ipv6 &&
                memcmp(a->ip, p->addr.ip, 4) == 0) continue;
            uint8_t c[6];
            memcpy(c, a->ip, 4);
            c[4] = (uint8_t)(a->port >> 8);
            c[5] = (uint8_t)(a->port & 0xff);
            bt_buf_append(&added, c, 6);
            uint8_t f = 0;
            bt_buf_append(&flags, &f, 1);
            n++;
        }
        if (n == 0) { bt_buf_free(&added); bt_buf_free(&flags); continue; }

        bt_be_value d;
        memset(&d, 0, sizeof(d));
        d.type = BT_BE_DICT;
        bt_be_value av = bt_be_strn(added.data, added.len);
        bt_be_dict_set(&d, "added", &av);
        bt_be_value fv = bt_be_strn(flags.data, flags.len);
        bt_be_dict_set(&d, "added.f", &fv);
        size_t len = 0;
        uint8_t *enc = bt_be_encode(&d, &len);
        bt_be_free(&d);
        bt_buf_free(&added);
        bt_buf_free(&flags);
        if (enc) {
            bt_peer_msg_extended(p, p->peer_ut_pex_id, enc, len);
            free(enc);
        }
    }
}

/* ---------- 主循环 ---------- */
int bt_engine_run(bt_engine *e) {
    memset(&e->cb, 0, sizeof(e->cb));
    e->cb.ctx = e;
    e->cb.on_established = cb_established;
    e->cb.on_bitfield = cb_bitfield;
    e->cb.on_have = cb_have;
    e->cb.on_piece = cb_piece;
    e->cb.on_choke = cb_choke;
    e->cb.on_unchoke = cb_unchoke;
    e->cb.on_interested = cb_interested;
    e->cb.on_request = cb_request;
    e->cb.on_ext_handshake = cb_ext_handshake;
    e->cb.on_extended = cb_extended;

    e->started = time(NULL);
    e->last_data = e->started;
    e->last_progress = e->started;
    e->last_speed_time = e->started;
    e->last_up_speed_time = e->started;
    e->last_announce = 0;
    e->last_pex = e->started;
    e->last_summary = e->started;
    e->summary_bytes = 0;
    e->assign_cursor = 0;
    e->last_dht = 0;
    e->listen_fd = -1;

    elog(e, "===== BT 任务开始 =====");

    /* 连接上限 150：iOS 进程默认 fd 软限制 256，先抬到 1024，否则大批连接会 EBADF */
    {
        struct rlimit rl;
        int lim = 0;
        if (getrlimit(RLIMIT_NOFILE, &rl) == 0) {
            rlim_t want = 1024;
            if (rl.rlim_max != RLIM_INFINITY && rl.rlim_max < want) want = rl.rlim_max;
            if (rl.rlim_cur < want) {
                rl.rlim_cur = want;
                setrlimit(RLIMIT_NOFILE, &rl);
                getrlimit(RLIMIT_NOFILE, &rl);
            }
            lim = (int)rl.rlim_cur;
        }
        elog(e, "连接上限 %d，进程 fd 限制 %d", BT_MAX_PEERS, lim);
    }

    /* 创建 DHT（node id 随机，端口与 TCP 一致）。必须提前到 metadata 下载之前，
     * 否则 magnet 模式拿元数据时只能靠 tracker，找不到支持 ut_metadata 的 peer。 */
    e->dht = bt_dht_create(NULL, e->port, dht_log_cb, e);
    memcpy(e->fetch_hash, e->tor.info_hash, 20);
    pthread_mutex_init(&e->dht_mu, NULL);
    if (e->dht && pthread_create(&e->dht_tid, NULL, dht_thread_main, e) == 0)
        e->dht_thread_started = 1;

    /* magnet：先下 metadata */
    if (e->magnet_mode) {
        int rc = metadata_download(e);
        if (rc != 0) {
            return rc == 2 ? 2 : 1;
        }
        if (metadata_to_torrent(e) != 0) {
            elog(e, "错误: %s", e->error);
            return 1;
        }
        e->magnet_mode = 0;
        e->need_metadata = 0;
    }

    elog(e, "种子: %s（%llu 字节，%u 片）", e->tor.name ? e->tor.name : "?",
         (unsigned long long)e->tor.total_length, e->tor.piece_count);

    /* 打开存储（读模式检测完整） */
    if (bt_storage_open_read(&e->st, e->tor.name, e->save_dir, e->tor.piece_length,
                             e->tor.piece_count, e->tor.files, e->tor.file_count,
                             e->error, sizeof(e->error)) != 0) {
        elog(e, "打开存储失败: %s", e->error);
        return 1;
    }
    e->storage_open = 1;

    int complete = bt_storage_is_complete(&e->st) && check_complete_marker(e);
    if (complete) {
        e->seeding = 1;
        elog(e, "检测到数据已完整，进入做种模式");
    } else {
        bt_storage_close(&e->st);
        e->storage_open = 0;
        if (bt_storage_open(&e->st, e->tor.name, e->save_dir, e->tor.piece_length,
                            e->tor.piece_count, e->tor.files, e->tor.file_count,
                            e->error, sizeof(e->error)) != 0) {
            elog(e, "打开存储失败: %s", e->error);
            return 1;
        }
        e->storage_open = 1;
        e->seeding = 0;
    }

    /* 缓存结果路径 */
    {
        bt_buf rb;
        bt_buf_init(&rb);
        for (int i = 0; i < e->st.file_count; i++) {
            if (i > 0) bt_buf_append(&rb, "\n", 1);
            bt_buf_append(&rb, e->st.paths[i], strlen(e->st.paths[i]));
        }
        bt_buf_append(&rb, "", 1);
        free(e->result_paths);
        e->result_paths = (char *)rb.data;
    }

    size_t nbits = (e->tor.piece_count + 7) / 8;
    e->have = (uint8_t *)calloc(nbits ? nbits : 1, 1);
    if (!e->have) {
        snprintf(e->error, sizeof(e->error), "内存不足");
        bt_storage_close(&e->st);
        return 1;
    }
    if (e->seeding) {
        memset(e->have, 0xff, nbits);
        e->done_pieces = e->tor.piece_count;
        e->bytes_written = e->tor.total_length;
        start_listen(e);
    }

    /* 初始找 peers */
    if (e->seeding) {
        gather_peers(e, NULL);
        elog(e, "做种中：等待 peer 连接/下载…");
    } else {
        gather_peers(e, "started");
        fill_active_pieces(e);
    }
    e->last_announce = time(NULL);

    while (!e->stop) {
        time_t now = time(NULL);

        /* 下载完成 → 转做种 */
        if (!e->seeding && e->done_pieces == e->tor.piece_count) {
            e->seeding = 1;
            start_listen(e);
            write_complete_marker(e);
            elog(e, "===== 下载完成，转入做种模式 =====");
            /* 对已有 peer 广播 bitfield + unchoke */
            for (int i = 0; i < e->peer_count; i++) {
                bt_peer *p = &e->peers[i];
                if (p->state == BT_PEER_ESTABLISHED) {
                    bt_peer_msg_bitfield(p, e->have, e->tor.piece_count);
                    bt_peer_msg_unchoke(p);
                    p->am_choking = 0;
                }
            }
            bt_peer_addr *l = NULL; int c = 0;
            announce_all(e, "completed", &l, &c);
            free(l);
            if (e->dht) bt_dht_announce(e->dht, e->tor.info_hash, e->port);
        }

        service_peers(e, e->seeding, 250);

        if (e->seeding) {
            /* 做种：定期 announce + PEX */
            if (now - e->last_announce >= 60) {
                bt_peer_addr *l = NULL; int c = 0;
                announce_all(e, NULL, &l, &c);
                for (int i = 0; i < c; i++) add_known_peer(e, &l[i]);
                free(l);
                if (e->dht) bt_dht_announce(e->dht, e->tor.info_hash, e->port);
                e->last_announce = now;
            }
            if (now - e->last_pex >= PEX_INTERVAL) {
                send_pex(e);
                e->last_pex = now;
            }
        } else {
            drop_dead_peers(e);
            fill_active_pieces(e);
            assign_requests(e);
            retry_timeouts(e);

            if (check_finish_pieces(e) != 0) {
                bt_engine_stop(e);
                break;
            }

            /* 下载阶段同样只取线程挖到的 peer，主循环零阻塞 */
            drain_dht_queue(e);

            /* 10 秒一行摘要：替换原先每片一条的刷屏日志 */
            if (now - e->last_summary >= BT_SUMMARY_INTERVAL) {
                time_t dt_sum = now - e->last_summary;
                if (dt_sum < 1) dt_sum = 1;
                e->last_summary = now;
                int inflight = 0, trusted = 0, active = 0;
                for (int k = 0; k < e->peer_count; k++) {
                    bt_peer *pk = &e->peers[k];
                    if (pk->state == BT_PEER_ESTABLISHED) {
                        inflight += pk->req_count;
                        if (pk->downloaded > 0) trusted++;
                    }
                }
                active = count_active(e);
                /* downloaded 现在只统计「首次填充」的块，不会再被重复数据污染；
                 * 关键是必须除以真实经过的秒数（之前漏了这一步才虚高） */
                int gap_pieces = 0, gap_blocks = 0;
                for (int k = 0; k < BT_MAX_ACTIVE_PIECES; k++) {
                    bt_active_piece *ap = &e->active[k];
                    if (!ap->active || !ap->filled) continue;
                    gap_pieces++;
                    for (uint32_t b = 0; b < ap->block_count; b++) if (!ap->filled[b]) gap_blocks++;
                }
                int64_t spd = (int64_t)((e->downloaded - e->summary_bytes) / (uint64_t)dt_sum);
                e->summary_bytes = e->downloaded;
                double pct = e->tor.total_length
                    ? (double)e->bytes_written * 100.0 / (double)e->tor.total_length : 0.0;
                elog(e, "进度 %u/%u 片（%.2f%%）· %.2f MB/s · 活跃 %d（有效 %d）· 在途块 %d · 缓冲 %d 片缺 %d 块 · 已知 %d",
                     e->done_pieces, e->tor.piece_count, pct,
                     (double)spd / 1048576.0, active, trusted, inflight,
                     gap_pieces, gap_blocks, e->known_count);
            }

            /* 速度/进度上报 */
            if (now - e->last_progress >= 1) {
                int64_t speed = 0;
                time_t dt = now - e->last_speed_time;
                if (dt > 0) speed = (int64_t)((e->downloaded - e->last_speed_bytes) / dt);
                e->last_speed_bytes = e->downloaded;
                e->last_speed_time = now;
                e->last_progress = now;
                if (e->progress) {
                    /* 进度用已接收字节（更平滑），但不超过总量 */
                    uint64_t done = e->downloaded;
                    if (done > e->tor.total_length) done = e->tor.total_length;
                    e->progress(e->ctx, done, e->tor.total_length,
                                count_active(e), speed);
                }
            }

            /* peer 不足重新找（连接上限提到 150 后要持续补充，不然池子挖到 389 个
             * 却只连了前 50 个死节点） */
            if (now - e->last_announce >= 60 && count_active(e) < 100 &&
                e->done_pieces < e->tor.piece_count) {
                gather_peers(e, NULL);
                e->last_announce = now;
            }

            /* 长时间无数据判失败 */
            if (now - e->last_data > BT_IDLE_TIMEOUT && e->done_pieces < e->tor.piece_count) {
                snprintf(e->error, sizeof(e->error), "长时间无数据传输（%d 秒）", BT_IDLE_TIMEOUT);
                elog(e, "错误: %s", e->error);
                bt_storage_close(&e->st);
                e->storage_open = 0;
                return 1;
            }
        }

        /* 做种时也上报进度（速度=上传） */
        if (e->seeding && now - e->last_progress >= 2) {
            int64_t speed = 0;
            time_t dt = now - e->last_up_speed_time;
            if (dt > 0) speed = (int64_t)((e->uploaded - e->last_up_speed_bytes) / dt);
            e->last_up_speed_bytes = e->uploaded;
            e->last_up_speed_time = now;
            e->last_progress = now;
            if (e->progress) {
                e->progress(e->ctx, e->bytes_written, e->tor.total_length,
                            count_active(e), speed);
            }
        }
    }

    bt_storage_close(&e->st);
    e->storage_open = 0;

    if (e->stop) {
        bt_peer_addr *l = NULL; int c = 0;
        announce_all(e, "stopped", &l, &c);
        free(l);
        elog(e, "===== 已手动停止 =====");
        return 2;
    }

    elog(e, "===== 任务结束 =====");
    return 0;
}

/* ---------- 创建/销毁 ---------- */
bt_engine *bt_engine_create(const bt_torrent *t, const char *save_dir,
                            bt_engine_log_fn log, bt_engine_progress_fn progress,
                            void *ctx,
                            bt_engine_announce_fn announce, void *announce_ctx) {
    bt_engine *e = (bt_engine *)calloc(1, sizeof(bt_engine));
    if (!e) return NULL;
    torrent_copy(&e->tor, t);
    e->save_dir = bt_strdup(save_dir);
    e->log = log;
    e->progress = progress;
    e->ctx = ctx;
    e->announce = announce;
    e->announce_ctx = announce_ctx;
    e->port = BT_LISTEN_PORT;
    e->magnet_mode = 0;
    e->need_metadata = 0;
    e->listen_fd = -1;
    bt_make_peer_id(e->peer_id);
    for (int i = 0; i < BT_MAX_PEERS; i++) {
        e->peers[i].fd = -1;
        e->peers[i].state = BT_PEER_CLOSED;
    }
    e->peer_count = BT_MAX_PEERS;
    return e;
}

bt_engine *bt_engine_create_magnet(const bt_magnet *m, const char *save_dir,
                                   bt_engine_log_fn log, bt_engine_progress_fn progress,
                                   void *ctx,
                                   bt_engine_announce_fn announce, void *announce_ctx) {
    bt_engine *e = (bt_engine *)calloc(1, sizeof(bt_engine));
    if (!e) return NULL;
    memset(&e->tor, 0, sizeof(e->tor));
    e->tor.name = bt_strdup(m->name ? m->name : "");
    memcpy(e->tor.info_hash, m->info_hash, 20);
    memcpy(e->tor.info_hash_hex, m->info_hash_hex, 41);
    e->tor.tracker_count = m->tracker_count;
    e->tor.trackers = (char **)calloc(m->tracker_count ? m->tracker_count : 1, sizeof(char *));
    for (uint32_t i = 0; i < m->tracker_count; i++)
        e->tor.trackers[i] = bt_strdup(m->trackers[i]);

    e->save_dir = bt_strdup(save_dir);
    e->log = log;
    e->progress = progress;
    e->ctx = ctx;
    e->announce = announce;
    e->announce_ctx = announce_ctx;
    e->port = BT_LISTEN_PORT;
    e->magnet_mode = 1;
    e->need_metadata = 1;
    e->listen_fd = -1;
    bt_make_peer_id(e->peer_id);
    for (int i = 0; i < BT_MAX_PEERS; i++) {
        e->peers[i].fd = -1;
        e->peers[i].state = BT_PEER_CLOSED;
    }
    e->peer_count = BT_MAX_PEERS;
    return e;
}

void bt_engine_destroy(bt_engine *e) {
    if (!e) return;
    if (e->dht_thread_started) {
        e->dht_thread_stop = 1;
        pthread_join(e->dht_tid, NULL);
        pthread_mutex_destroy(&e->dht_mu);
    }
    for (int i = 0; i < e->peer_count; i++) {
        bt_peer_free(&e->peers[i]);
    }
    if (e->storage_open) bt_storage_close(&e->st);
    if (e->dht) bt_dht_destroy(e->dht);
    if (e->listen_fd >= 0) close(e->listen_fd);
    bt_torrent_free(&e->tor);
    free(e->save_dir);
    free(e->have);
    for (int i = 0; i < BT_MAX_ACTIVE_PIECES; i++) {
        free(e->active[i].buf);
        free(e->active[i].blocks);
        free(e->active[i].filled);
        free(e->active[i].dup);
    }
    free(e->result_paths);
    free(e->metadata.data);
    free(e->metadata_flags);
    free(e->meta_tries);
    free(e);
}

void bt_engine_stop(bt_engine *e) {
    if (!e) return;
    e->stop = 1;
    e->dht_thread_stop = 1;     /* 让 DHT 线程立刻醒来退出，别让 destroy 干等 8 秒 */
}

const char *bt_engine_error(const bt_engine *e) {
    return e->error;
}

char *bt_engine_result_paths(const bt_engine *e) {
    return bt_strdup(e->result_paths ? e->result_paths : "");
}
