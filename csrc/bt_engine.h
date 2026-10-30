#ifndef BT_ENGINE_H
#define BT_ENGINE_H

#include <stdint.h>
#include <stddef.h>
#include "bt_torrent.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct bt_engine bt_engine;

struct bt_peer_addr;
struct bt_magnet;

typedef void (*bt_engine_log_fn)(void *ctx, const char *line);
typedef void (*bt_engine_progress_fn)(void *ctx, uint64_t done, uint64_t total,
                                      int peers, int64_t speed);

/* 外部 tracker announce：返回 0 成功并填充 peers 等；否则非 0 且 err 写信息。
 * 若为 NULL，则引擎用内置的 http 实现（bt_tracker_announce）。 */
typedef int (*bt_engine_announce_fn)(void *ctx, const char *url,
                                     const uint8_t info_hash[20], const uint8_t peer_id[20],
                                     uint16_t port, int64_t uploaded, int64_t downloaded,
                                     int64_t left, const char *event,
                                     struct bt_peer_addr **out_peers, int *out_count,
                                     int *out_interval, int *out_seeders, int *out_leechers,
                                     char *err, size_t errlen);

bt_engine *bt_engine_create(const bt_torrent *t, const char *save_dir,
                            bt_engine_log_fn log, bt_engine_progress_fn progress,
                            void *ctx,
                            bt_engine_announce_fn announce, void *announce_ctx);

/* 从 magnet 链接创建（无元数据，运行时先通过 DHT/tracker + ut_metadata 下载元数据）。 */
bt_engine *bt_engine_create_magnet(const struct bt_magnet *m, const char *save_dir,
                                   bt_engine_log_fn log, bt_engine_progress_fn progress,
                                   void *ctx,
                                   bt_engine_announce_fn announce, void *announce_ctx);

void bt_engine_destroy(bt_engine *e);

/* 阻塞运行直到完成 / 失败 / 停止。
 * 返回 0=完成，1=失败，2=被停止。 */
int bt_engine_run(bt_engine *e);

/* 线程安全地请求停止（从 UI 线程调用）。 */
void bt_engine_stop(bt_engine *e);

const char *bt_engine_error(const bt_engine *e);

/* 输出最终保存目录下的文件路径列表（用 \n 分隔，调用方 free）。 */
char *bt_engine_result_paths(const bt_engine *e);

#ifdef __cplusplus
}
#endif

#endif /* BT_ENGINE_H */
