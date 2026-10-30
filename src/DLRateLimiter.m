#import "DLRateLimiter.h"
#import <unistd.h>

@implementation DLRateLimiter {
    NSLock *_lock;
    int64_t _limit;      // B/s，0 = 不限
    double _tokens;      // 当前可用字节
    double _lastRefill;  // 上次补充时间（秒）
}

+ (instancetype)shared {
    static DLRateLimiter *r;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ r = [[DLRateLimiter alloc] init]; });
    return r;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = [[NSLock alloc] init];
        _tokens = 0;
        _lastRefill = 0;
    }
    return self;
}

- (void)setLimitBytesPerSecond:(int64_t)b {
    [_lock lock];
    _limit = b;
    _tokens = 0; // 从零开始攒，切换限速后不会先跑满一秒再限
    _lastRefill = [[NSDate date] timeIntervalSince1970];
    [_lock unlock];
}

- (void)consume:(int64_t)bytes {
    if (bytes <= 0) return;
    [_lock lock];
    int64_t lim = _limit;
    [_lock unlock];
    if (lim <= 0) return; // 不限速

    for (;;) {
        [_lock lock];
        double now = [[NSDate date] timeIntervalSince1970];
        double elapsed = now - _lastRefill;
        if (elapsed > 0) {
            _tokens += elapsed * (double)lim;
            double cap = (double)lim;
            if (_tokens > cap) _tokens = cap;
            _lastRefill = now;
        }
        if (_tokens >= (double)bytes) {
            _tokens -= (double)bytes;
            [_lock unlock];
            return;
        }
        /* 按缺口精确睡，不再 20ms 空转轮询（限速时每秒空转 50 次、白耗 CPU） */
        double need = ((double)bytes - _tokens) / (double)lim;
        [_lock unlock];
        if (need < 0.001) need = 0.001;
        if (need > 1.0) need = 1.0;
        usleep((useconds_t)(need * 1000000.0));
    }
}

@end
