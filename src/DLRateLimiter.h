#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 全局令牌桶限速器。仅对 foreground dataTask 生效（background downloadTask 数据不经过这里）。
@interface DLRateLimiter : NSObject

+ (instancetype)shared;

/// bytesPerSecond：0 = 不限速
- (void)setLimitBytesPerSecond:(int64_t)bytesPerSecond;

/// 阻塞当前线程直到配额充足（在后台串行 delegate 队列上调用，实现 TCP 流控式限速）
- (void)consume:(int64_t)bytes;

@end

NS_ASSUME_NONNULL_END
