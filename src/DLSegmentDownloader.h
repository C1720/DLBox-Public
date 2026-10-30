#import <Foundation/Foundation.h>

@class DLTask, DLRateLimiter;

NS_ASSUME_NONNULL_BEGIN

/// 负责「单个任务」的多段并发下载：分 N 段用 dataTask + Range 下载到 part-N 文件，全部完成后拼接成目标文件。
/// dataTask 的 delegate 回调统一走引擎（NSURLSession delegate 唯一），引擎按 taskDescription 解析后转发到这里。
@interface DLSegmentDownloader : NSObject

/// 全部段完成后回调（destPath = 拼接后的最终文件路径）。回调在后台 delegate 队列上。
@property (nonatomic, copy, nullable) void (^onFinished)(NSString *destPath);

- (instancetype)initWithTask:(DLTask *)task
                     session:(NSURLSession *)session
                     partDir:(NSString *)partDir
                    destPath:(NSString *)destPath
                 rateLimiter:(DLRateLimiter *)rateLimiter;

/// 启动：若 task.segments 已有则续传，否则按 task.totalBytes/segmentCount 重新分段。
- (void)start;

/// 取消所有 dataTask 并关闭文件句柄（保留 part 与已下载字节，供断点续传）。
- (void)cancel;

/// 把内存中的分段进度写回 task.segments（暂停/持久化前调用）。
- (void)syncToTask;

// —— 引擎转发的 dataTask 回调 ——
- (void)receiveData:(NSData *)data atIndex:(NSInteger)index;
- (void)segmentFinishedAtIndex:(NSInteger)index;

- (NSInteger)segmentCount;

@end

NS_ASSUME_NONNULL_END
