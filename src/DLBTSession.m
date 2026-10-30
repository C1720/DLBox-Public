#import "DLBTSession.h"
#import "DLLog.h"
#import <pthread/pthread.h>
#include "bt_engine.h"
#include "bt_torrent.h"
#include "bt_tracker.h"
#include "bt_magnet.h"

NSNotificationName const DLBTSessionLogNotification = @"DLBTSessionLogNotification";
NSNotificationName const DLBTSessionProgressNotification = @"DLBTSessionProgressNotification";
NSNotificationName const DLBTSessionStateNotification = @"DLBTSessionStateNotification";

@interface DLBTSession ()
- (void)appendLogLine:(NSString *)line;
- (void)updateProgress:(uint64_t)done total:(uint64_t)total peers:(int)peers speed:(int64_t)speed;
- (void)handleFinished:(int)rc engine:(bt_engine *)e;
@end

static void bt_log_cb(void *ctx, const char *line) {
    DLBTSession *s = (__bridge DLBTSession *)ctx;
    NSString *str = [NSString stringWithUTF8String:line];
    if (!str) return;
    /* 引擎线程直接落盘：闪退时内存里的日志会一起消失，文件里的还在 */
    [DLLog write:str];
    dispatch_async(dispatch_get_main_queue(), ^{
        [s appendLogLine:str];
    });
}

static void bt_progress_cb(void *ctx, uint64_t done, uint64_t total, int peers, int64_t speed) {
    DLBTSession *s = (__bridge DLBTSession *)ctx;
    dispatch_async(dispatch_get_main_queue(), ^{
        [s updateProgress:done total:total peers:peers speed:speed];
    });
}

static void *bt_run_thread(void *arg) {
    bt_engine *e = (bt_engine *)arg;
    int rc = bt_engine_run(e);
    dispatch_async(dispatch_get_main_queue(), ^{
        [[DLBTSession shared] handleFinished:rc engine:e];
    });
    return NULL;
}

/* 同步 GET（http/https 皆可），返回 body，失败返回 nil 并写 err */
static NSData *bt_sync_get(const char *url, char *err, size_t errlen) {
    NSString *urlStr = [NSString stringWithUTF8String:url];
    __block NSData *result = nil;
    __block NSString *errStr = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    req.timeoutInterval = 15;
    [req setValue:@"DLBox/0.2" forHTTPHeaderField:@"User-Agent"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        if (e) {
            errStr = e.localizedDescription;
        } else {
            NSHTTPURLResponse *hr = (NSHTTPURLResponse *)r;
            if (hr.statusCode != 200) {
                errStr = [NSString stringWithFormat:@"HTTP %ld", (long)hr.statusCode];
            } else {
                result = d;
            }
        }
        dispatch_semaphore_signal(sem);
    }] resume];

    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC));
    if (errStr && err && errlen) {
        snprintf(err, errlen, "%s", errStr.UTF8String);
    }
    return result;
}

/* 外部 announce：用 NSURLSession 请求 tracker（支持 http 与 https），解析复用 C 侧 */
static int objc_announce(void *ctx, const char *url,
                         const uint8_t info_hash[20], const uint8_t peer_id[20],
                         uint16_t port, int64_t uploaded, int64_t downloaded,
                         int64_t left, const char *event,
                         bt_peer_addr **out_peers, int *out_count,
                         int *out_interval, int *out_seeders, int *out_leechers,
                         char *err, size_t errlen)
{
    (void)ctx;
    char ih[61], pid[61];
    bt_tracker_url_encode(info_hash, 20, ih, sizeof(ih));
    bt_tracker_url_encode(peer_id, 20, pid, sizeof(pid));

    char query[2048];
    snprintf(query, sizeof(query),
             "info_hash=%s&peer_id=%s&port=%u&uploaded=%lld&downloaded=%lld&left=%lld&compact=1&numwant=80%s%s",
             ih, pid, port, (long long)uploaded, (long long)downloaded, (long long)left,
             event ? "&event=" : "", event ? event : "");

    char full[4096];
    snprintf(full, sizeof(full), "%s%s%s", url, (strchr(url, '?') ? "&" : "?"), query);

    NSData *data = bt_sync_get(full, err, errlen);
    if (!data) return -1;

    return bt_tracker_parse_response((const uint8_t *)data.bytes, data.length,
                                     out_peers, out_count, out_interval,
                                     out_seeders, out_leechers, err, errlen);
}

@implementation DLBTSession {
    bt_engine *_engine;
    pthread_t _thread;
    BOOL _threadRunning;
    NSMutableString *_log;
}

+ (instancetype)shared {
    static DLBTSession *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [[DLBTSession alloc] init];
    });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _log = [NSMutableString string];
        _state = DLBTSessionStateIdle;
    }
    return self;
}

#pragma mark - 回调（主线程）

- (void)appendLogLine:(NSString *)line {
    [_log appendFormat:@"%@\n", line];
    /* 限制日志长度，避免无限增长导致 UI 卡顿 / 跳动 */
    if (_log.length > 60000) {
        NSUInteger cut = _log.length - 40000;
        NSRange r = [_log rangeOfString:@"\n" options:0 range:NSMakeRange(cut, _log.length - cut)];
        if (r.location != NSNotFound) {
            [_log deleteCharactersInRange:NSMakeRange(0, r.location + 1)];
        } else {
            [_log deleteCharactersInRange:NSMakeRange(0, cut)];
        }
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:DLBTSessionLogNotification
                                                        object:self
                                                      userInfo:@{@"line": line}];
}

- (void)updateProgress:(uint64_t)done total:(uint64_t)total peers:(int)peers speed:(int64_t)speed {
    _doneBytes = done;
    _totalBytes = total;
    _peerCount = peers;
    _speed = speed;
    [[NSNotificationCenter defaultCenter] postNotificationName:DLBTSessionProgressNotification
                                                        object:self
                                                      userInfo:@{
        @"done": @(done),
        @"total": @(total),
        @"peers": @(peers),
        @"speed": @(speed),
    }];
}

- (void)handleFinished:(int)rc engine:(bt_engine *)e {
    _threadRunning = NO;
    if (rc == 0) {
        _state = DLBTSessionStateCompleted;
        const char *rp = bt_engine_result_paths(e);
        _resultPaths = rp ? [NSString stringWithUTF8String:rp] : @"";
        free((void *)rp);
        [self appendLogLine:@"✅ 下载完成"];
    } else if (rc == 2) {
        _state = DLBTSessionStateStopped;
        [self appendLogLine:@"⏹ 已停止"];
    } else {
        _state = DLBTSessionStateFailed;
        const char *err = bt_engine_error(e);
        NSString *errStr = (err && *err) ? [NSString stringWithUTF8String:err] : @"未知错误";
        [self appendLogLine:[NSString stringWithFormat:@"❌ 失败: %@", errStr]];
    }
    bt_engine_destroy(e);
    if (_engine == e) _engine = NULL;
    [[NSNotificationCenter defaultCenter] postNotificationName:DLBTSessionStateNotification
                                                        object:self
                                                      userInfo:@{@"state": @(_state)}];
}

#pragma mark - 对外

- (BOOL)startWithTorrentData:(NSData *)data error:(NSString * _Nullable * _Nullable)err {
    if (_threadRunning || _engine) {
        if (err) *err = @"已有任务在运行，请先停止";
        return NO;
    }

    bt_torrent tor;
    char perr[256] = {0};
    if (bt_torrent_parse((const uint8_t *)data.bytes, data.length, &tor, perr, sizeof(perr)) != 0) {
        if (err) *err = [NSString stringWithUTF8String:perr];
        return NO;
    }

    [_log setString:@""];
    _resultPaths = @"";
    _doneBytes = 0;
    _totalBytes = tor.total_length;
    _peerCount = 0;
    _speed = 0;
    _name = tor.name ? [NSString stringWithUTF8String:tor.name] : @"(未知)";

    char *summary = bt_torrent_summary(&tor);
    if (summary) {
        [self appendLogLine:[NSString stringWithUTF8String:summary]];
        free(summary);
    }

    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *saveDir = [docs stringByAppendingPathComponent:@"dlbox/downloads"];

    _engine = bt_engine_create(&tor, saveDir.UTF8String, bt_log_cb, bt_progress_cb,
                               (__bridge void *)self, objc_announce, (__bridge void *)self);
    bt_torrent_free(&tor);

    return [self launchEngineWithError:err];
}

- (BOOL)startWithMagnet:(NSString *)url error:(NSString * _Nullable * _Nullable)err {
    if (_threadRunning || _engine) {
        if (err) *err = @"已有任务在运行，请先停止";
        return NO;
    }

    bt_magnet m;
    char perr[256] = {0};
    if (bt_magnet_parse(url.UTF8String, &m, perr, sizeof(perr)) != 0) {
        if (err) *err = [NSString stringWithUTF8String:perr];
        return NO;
    }

    [_log setString:@""];
    _resultPaths = @"";
    _doneBytes = 0;
    _totalBytes = 0;   /* 元数据未下载，大小未知 */
    _peerCount = 0;
    _speed = 0;
    if (m.name && *m.name) {
        _name = [NSString stringWithUTF8String:m.name];
    } else {
        _name = [NSString stringWithFormat:@"magnet:%@", [NSString stringWithUTF8String:m.info_hash_hex]];
    }

    [self appendLogLine:[NSString stringWithFormat:@"magnet 链接 · info_hash %@", [NSString stringWithUTF8String:m.info_hash_hex]]];
    [self appendLogLine:@"第一步：通过 DHT/tracker + ut_metadata 获取种子元数据…"];

    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *saveDir = [docs stringByAppendingPathComponent:@"dlbox/downloads"];

    _engine = bt_engine_create_magnet(&m, saveDir.UTF8String, bt_log_cb, bt_progress_cb,
                                      (__bridge void *)self, objc_announce, (__bridge void *)self);
    bt_magnet_free(&m);

    return [self launchEngineWithError:err];
}

- (BOOL)launchEngineWithError:(NSString * _Nullable * _Nullable)err {
    if (!_engine) {
        if (err) *err = @"引擎创建失败";
        return NO;
    }

    _state = DLBTSessionStateRunning;
    [[NSNotificationCenter defaultCenter] postNotificationName:DLBTSessionStateNotification
                                                        object:self
                                                      userInfo:@{@"state": @(_state)}];

    _threadRunning = YES;
    if (pthread_create(&_thread, NULL, bt_run_thread, _engine) != 0) {
        _threadRunning = NO;
        bt_engine_destroy(_engine);
        _engine = NULL;
        _state = DLBTSessionStateFailed;
        if (err) *err = @"线程创建失败";
        return NO;
    }
    pthread_detach(_thread);
    return YES;
}

- (void)stop {
    if (_engine) bt_engine_stop(_engine);
}

- (void)reset {
    if (_threadRunning) return;
    _state = DLBTSessionStateIdle;
    _doneBytes = 0;
    _totalBytes = 0;
    _peerCount = 0;
    _speed = 0;
    _name = @"";
    _resultPaths = @"";
    [_log setString:@""];
}

- (NSString *)logText {
    return [_log copy];
}

- (BOOL)seeding {
    return _state == DLBTSessionStateRunning && _totalBytes > 0 && _doneBytes >= _totalBytes;
}

@end
