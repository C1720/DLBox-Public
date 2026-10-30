#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DLSettings : NSObject

+ (instancetype)shared;

@property (nonatomic, assign) NSInteger maxConcurrent;   // 并发下载任务数 1~6，默认 2
@property (nonatomic, assign) NSInteger segmentCount;    // 每任务分段数 1~8，默认 4
@property (nonatomic, assign) NSInteger rateLimitKBs;    // 限速 KB/s，0 = 不限
@property (nonatomic, assign) BOOL allowHTTP;            // 允许 http 明文链接，默认 YES
@property (nonatomic, assign) NSInteger downloadMode;    // 0 分段加速 / 1 后台整段

@end

NS_ASSUME_NONNULL_END
