#import <Foundation/Foundation.h>

@class DLTask;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const DLDownloadTasksChangedNotification;
FOUNDATION_EXPORT NSString * const DLDownloadProgressNotification;

@interface DLDownloadEngine : NSObject

@property (nonatomic, assign) NSInteger maxConcurrentDownloads;
@property (nonatomic, copy, nullable) void (^backgroundSessionCompletionHandler)(void);

+ (instancetype)sharedEngine;

/// 启动：从磁盘恢复任务队列，并接管后台会话中仍在进行的下载。
- (void)start;

/// 入队一个下载任务，成功返回 taskId，非法 URL 返回 nil。
- (nullable NSString *)enqueueURL:(NSURL *)url fileName:(nullable NSString *)fileName;

- (void)pauseTask:(NSString *)taskId;
- (void)resumeTask:(NSString *)taskId;
- (void)removeTask:(NSString *)taskId;

- (NSArray<DLTask *> *)allTasks;

/// 应用 DLSettings（并发数 / 限速），设置页改动后调用。
- (void)applySettings;

/// 后台会话事件接管入口（由 AppDelegate 转发）。
- (void)handleEventsForBackgroundURLSession:(NSString *)identifier
                          completionHandler:(void (^)(void))completionHandler;

@end

NS_ASSUME_NONNULL_END
