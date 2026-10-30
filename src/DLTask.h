#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, DLTaskState) {
    DLTaskStateWaiting = 0,
    DLTaskStateRunning,
    DLTaskStatePaused,
    DLTaskStateCompleted,
    DLTaskStateFailed,
};

typedef NS_ENUM(NSInteger, DLDownloadMode) {
    DLDownloadModeSegmented = 0,   // 多段并发加速（foreground dataTask + Range）
    DLDownloadModeBackground = 1,  // 后台整段（background downloadTask）
};

@interface DLTask : NSObject

@property (nonatomic, copy) NSString *taskId;
@property (nonatomic, copy) NSString *urlString;
@property (nonatomic, copy) NSString *fileName;
@property (nonatomic, assign) DLTaskState state;
@property (nonatomic, assign) int64_t totalBytes;     // 0 = 未知
@property (nonatomic, assign) int64_t receivedBytes;  // 已收字节
@property (nonatomic, copy, nullable) NSString *errorMessage;
@property (nonatomic, assign) NSTimeInterval createdAt;
@property (nonatomic, assign) NSTimeInterval updatedAt;

// —— 下载方式（持久化）——
@property (nonatomic, assign) DLDownloadMode mode;
@property (nonatomic, assign) NSInteger segmentCount;    // 分段数（1 = 单段）
@property (nonatomic, assign) BOOL probed;               // 是否已完成 Range 探测
@property (nonatomic, assign) BOOL supportsRange;        // 服务器是否支持 Range
@property (nonatomic, strong, nullable) NSArray<NSDictionary *> *segments; // 分段状态 @[@{start,end,done}]

// —— 运行期字段（不持久化）——
@property (nonatomic, weak, nullable) NSURLSessionDownloadTask *sessionTask;
@property (nonatomic, assign) int64_t baseBytes;         // background 续传起始偏移
@property (nonatomic, assign) BOOL cancelForPause;
@property (nonatomic, assign) int64_t speed;             // 瞬时速度 B/s
@property (nonatomic, assign) int64_t speedBytes;        // 上次测速时的 receivedBytes
@property (nonatomic, assign) NSTimeInterval speedTime;  // 上次测速时间

- (instancetype)initWithURLString:(NSString *)urlString fileName:(nullable NSString *)fileName;

- (NSDictionary *)dictionaryRepresentation;
+ (nullable instancetype)taskFromDictionary:(NSDictionary *)dict;

- (NSString *)stateName;
- (NSString *)modeName;
- (double)progress; // 0.0 ~ 1.0，未知 0

@end

NS_ASSUME_NONNULL_END
