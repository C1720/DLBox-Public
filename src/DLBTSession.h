#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, DLBTSessionState) {
    DLBTSessionStateIdle = 0,
    DLBTSessionStateRunning,
    DLBTSessionStateCompleted,
    DLBTSessionStateFailed,
    DLBTSessionStateStopped,
};

extern NSNotificationName const DLBTSessionLogNotification;
extern NSNotificationName const DLBTSessionProgressNotification;
extern NSNotificationName const DLBTSessionStateNotification;

@interface DLBTSession : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly) DLBTSessionState state;
@property (nonatomic, readonly) uint64_t doneBytes;
@property (nonatomic, readonly) uint64_t totalBytes;
@property (nonatomic, readonly) NSInteger peerCount;
@property (nonatomic, readonly) int64_t speed;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly, copy) NSString *logText;
@property (nonatomic, readonly, copy) NSString *resultPaths;
/* 是否处于做种状态（下载完成后的上传阶段） */
@property (nonatomic, readonly) BOOL seeding;

/* 从 .torrent 数据启动下载，返回是否成功 */
- (BOOL)startWithTorrentData:(NSData *)data error:(NSString * _Nullable * _Nullable)err;

/* 从 magnet 链接启动（先下元数据，再下载，完成后做种），返回是否成功 */
- (BOOL)startWithMagnet:(NSString *)url error:(NSString * _Nullable * _Nullable)err;

- (void)stop;
- (void)reset;

@end

NS_ASSUME_NONNULL_END
