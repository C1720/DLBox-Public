#import "DLDownloadEngine.h"
#import "DLTask.h"
#import "DLTaskStore.h"
#import "DLSettings.h"
#import "DLRateLimiter.h"
#import "DLSegmentDownloader.h"

NSString * const DLDownloadTasksChangedNotification = @"DLDownloadTasksChangedNotification";
NSString * const DLDownloadProgressNotification = @"DLDownloadProgressNotification";

static NSString * const kBackgroundSessionIdentifier = @"dev.dlbox.app.background";
static NSString * const kProbeSuffix = @"|probe";

@interface DLDownloadEngine () <NSURLSessionDelegate, NSURLSessionDownloadDelegate, NSURLSessionDataDelegate>
@property (nonatomic, strong) NSURLSession *session;            // background（后台整段）
@property (nonatomic, strong) NSURLSession *foregroundSession;  // foreground（分段 dataTask）
@property (nonatomic, strong) DLTaskStore *store;
@property (nonatomic, assign) NSTimeInterval lastProgressNotify;
@property (nonatomic, assign) NSTimeInterval lastSaveTime; // 落盘节流（进度不需要每次都写盘）
@property (nonatomic, strong) NSRecursiveLock *lock;
@property (nonatomic, strong) NSMutableDictionary<NSString *, DLSegmentDownloader *> *segmenters;
@property (nonatomic, strong) NSOperationQueue *foregroundQueue;
@end

@implementation DLDownloadEngine

+ (instancetype)sharedEngine {
    static DLDownloadEngine *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[DLDownloadEngine alloc] init]; });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _maxConcurrentDownloads = 2;
        _lock = [[NSRecursiveLock alloc] init];
        _segmenters = [NSMutableDictionary dictionary];
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        _store = [[DLTaskStore alloc] initWithRootPath:[docs stringByAppendingPathComponent:@"dlbox"]];
        [self applySettings];
    }
    return self;
}

#pragma mark - Session

- (NSOperationQueue *)foregroundQueue {
    if (!_foregroundQueue) {
        _foregroundQueue = [[NSOperationQueue alloc] init];
        _foregroundQueue.name = @"dev.dlbox.app.foreground";
        _foregroundQueue.maxConcurrentOperationCount = 1; // 串行
    }
    return _foregroundQueue;
}

- (NSURLSession *)session {
    if (!_session) {
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:kBackgroundSessionIdentifier];
        cfg.allowsCellularAccess = YES;
        cfg.discretionary = NO;
        cfg.sessionSendsLaunchEvents = YES;
        cfg.timeoutIntervalForRequest = 60.0;
        cfg.HTTPMaximumConnectionsPerHost = 4;
        _session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];
    }
    return _session;
}

- (NSURLSession *)foregroundSession {
    if (!_foregroundSession) {
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        cfg.timeoutIntervalForRequest = 60.0;
        cfg.HTTPMaximumConnectionsPerHost = 8;
        cfg.allowsCellularAccess = YES;
        cfg.discretionary = NO;
        cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        _foregroundSession = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:self.foregroundQueue];
    }
    return _foregroundSession;
}

#pragma mark - Settings

- (void)applySettings {
    DLSettings *s = [DLSettings shared];
    self.maxConcurrentDownloads = s.maxConcurrent;
    [[DLRateLimiter shared] setLimitBytesPerSecond:(int64_t)s.rateLimitKBs * 1024];
    /* 并发数改大后要立刻把等待中的任务推起来，否则要等下一次事件才生效 */
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf pump];
    });
}

#pragma mark - Public API

- (void)start {
    [self applySettings];
    [self.store load];
    NSURLSession *s = self.session;
    [s getTasksWithCompletionHandler:^(NSArray<NSURLSessionTask *> *dataTasks,
                                       NSArray<NSURLSessionUploadTask *> *uploadTasks,
                                       NSArray<NSURLSessionDownloadTask *> *downloadTasks) {
        [self.lock lock];
        for (NSURLSessionDownloadTask *t in downloadTasks) {
            DLTask *task = [self.store taskWithId:t.taskDescription];
            if (task) {
                task.sessionTask = t;
                if (task.state == DLTaskStateWaiting) task.state = DLTaskStateRunning;
            }
        }
        // 标记 running 但系统没还回来的任务降级为 waiting（分段任务的 dataTask 不随进程恢复）
        for (DLTask *task in self.store.tasks) {
            if (task.state == DLTaskStateRunning && task.sessionTask == nil) {
                task.state = DLTaskStateWaiting;
            }
        }
        [self.store save];
        [self.lock unlock];
        [self pump];
        [self notifyTasksChanged];
    }];
}

- (NSString *)enqueueURL:(NSURL *)url fileName:(NSString *)fileName {
    if (!url) return nil;
    NSString *scheme = url.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return nil;
    if ([scheme isEqualToString:@"http"] && ![DLSettings shared].allowHTTP) return nil;

    [self.lock lock];
    /* 同一 URL 已有未完成任务就不再加一份（爬虫里手滑勾两次会下两份） */
    for (DLTask *t in self.store.tasks) {
        if ([t.urlString isEqualToString:url.absoluteString] &&
            (t.state == DLTaskStateWaiting || t.state == DLTaskStateRunning)) {
            NSString *existing = t.taskId;
            [self.lock unlock];
            return existing;
        }
    }
    DLTask *task = [[DLTask alloc] initWithURLString:url.absoluteString fileName:fileName];
    task.mode = (DLDownloadMode)[DLSettings shared].downloadMode;
    task.segmentCount = [DLSettings shared].segmentCount;
    [self.store insertTask:task];
    [self.store save];
    [self.lock unlock];
    [self notifyTasksChanged];
    [self pump];
    return task.taskId;
}

- (void)pauseTask:(NSString *)taskId {
    [self.lock lock];
    DLTask *task = [self.store taskWithId:taskId];
    if (!task) { [self.lock unlock]; return; }

    if (task.mode == DLDownloadModeBackground) {
        NSURLSessionDownloadTask *t = task.sessionTask;
        if (t && task.state == DLTaskStateRunning) {
            task.cancelForPause = YES;
            [t cancelByProducingResumeData:^(NSData * _Nullable resumeData) {
                [self.lock lock];
                if (resumeData) {
                    [self.store saveResumeData:resumeData forTask:task];
                    int64_t br = [DLDownloadEngine bytesFromResumeData:resumeData];
                    if (br > 0) task.receivedBytes = br;
                }
                task.state = DLTaskStatePaused;
                task.sessionTask = nil;
                task.cancelForPause = NO;
                task.speed = 0;
                [self.store save];
                [self.lock unlock];
                [self pump];
                [self notifyTasksChanged];
            }];
        } else if (task.state == DLTaskStateWaiting || task.state == DLTaskStateFailed) {
            task.state = DLTaskStatePaused;
            task.speed = 0;
            [self.store save];
            [self notifyTasksChanged];
        }
    } else {
        // 分段模式
        DLSegmentDownloader *d = self.segmenters[task.taskId];
        if (task.state == DLTaskStateRunning) {
            if (d) {
                [d syncToTask];
                [d cancel];
                [self.segmenters removeObjectForKey:task.taskId];
            }
            task.state = DLTaskStatePaused;
            task.speed = 0;
            [self.store save];
            [self notifyTasksChanged];
            [self pump];
        } else if (task.state == DLTaskStateWaiting || task.state == DLTaskStateFailed) {
            task.state = DLTaskStatePaused;
            task.speed = 0;
            [self.store save];
            [self notifyTasksChanged];
        }
    }
    [self.lock unlock];
}

- (void)resumeTask:(NSString *)taskId {
    [self.lock lock];
    DLTask *task = [self.store taskWithId:taskId];
    if (task && (task.state == DLTaskStatePaused || task.state == DLTaskStateFailed)) {
        task.state = DLTaskStateWaiting;
        task.errorMessage = nil;
        [self.store save];
    }
    [self.lock unlock];
    [self notifyTasksChanged];
    [self pump];
}

- (void)removeTask:(NSString *)taskId {
    [self.lock lock];
    DLTask *task = [self.store taskWithId:taskId];
    if (task) {
        if (task.mode == DLDownloadModeBackground) {
            [task.sessionTask cancel];
            task.sessionTask = nil;
            [self.store deleteResumeDataForTask:task];
        } else {
            DLSegmentDownloader *d = self.segmenters[taskId];
            if (d) {
                [d cancel];
                [self.segmenters removeObjectForKey:taskId];
            }
            [self.store deletePartDirForTask:task];
        }
        [self.store removeTask:task];
        [self.store save];
    }
    [self.lock unlock];
    [self notifyTasksChanged];
    [self pump];
}

- (NSArray<DLTask *> *)allTasks {
    [self.lock lock];
    NSArray *copy = [self.store.tasks copy];
    [self.lock unlock];
    return copy;
}

- (void)handleEventsForBackgroundURLSession:(NSString *)identifier completionHandler:(void (^)(void))completionHandler {
    self.backgroundSessionCompletionHandler = completionHandler;
    [self session];
}

#pragma mark - Scheduling

- (void)pump {
    [self.lock lock];
    NSInteger running = 0;
    for (DLTask *t in self.store.tasks) {
        if (t.state == DLTaskStateRunning) running++;
    }
    if (running < self.maxConcurrentDownloads) {
        for (DLTask *t in self.store.tasks) {
            if (running >= self.maxConcurrentDownloads) break;
            if (t.state == DLTaskStateWaiting) {
                [self startTask:t];
                running++;
            }
        }
    }
    [self.lock unlock];
}

- (void)startTask:(DLTask *)task {
    if (task.mode == DLDownloadModeBackground) {
        [self startBackgroundTask:task];
    } else {
        [self startSegmentedTask:task];
    }
}

#pragma mark - Background (整段) 下载

- (void)startBackgroundTask:(DLTask *)task {
    NSData *resume = [self.store loadResumeDataForTask:task];
    NSURLSessionDownloadTask *t;
    if (resume) {
        task.baseBytes = [DLDownloadEngine bytesFromResumeData:resume];
        t = [self.session downloadTaskWithResumeData:resume];
    } else {
        task.baseBytes = 0;
        t = [self.session downloadTaskWithURL:[NSURL URLWithString:task.urlString]];
    }
    t.taskDescription = task.taskId;
    task.sessionTask = t;
    task.state = DLTaskStateRunning;
    task.errorMessage = nil;
    task.speed = 0;
    task.speedTime = 0;
    task.speedBytes = 0;
    [t resume];
    [self.store save];
}

#pragma mark - Segmented (多段) 下载

- (void)startSegmentedTask:(DLTask *)task {
    task.state = DLTaskStateRunning;
    task.errorMessage = nil;
    task.speed = 0;
    task.speedTime = 0;
    task.speedBytes = 0;

    NSString *partDir = [self.store partDirForTask:task];
    // 先写临时路径，全部拼完再重命名到最终位置，避免同名任务抢占同一文件名
    NSString *tmp = [self.store.downloadsPath stringByAppendingPathComponent:[NSString stringWithFormat:@".tmp-%@", task.taskId]];

    DLSegmentDownloader *d = [[DLSegmentDownloader alloc] initWithTask:task
                                                               session:self.foregroundSession
                                                               partDir:partDir
                                                              destPath:tmp
                                                           rateLimiter:[DLRateLimiter shared]];
    __weak typeof(self) weakSelf = self;
    NSString *tid = task.taskId;
    d.onFinished = ^(NSString *tmpPath) {
        [weakSelf segmentedTaskFinished:tid tmpPath:tmpPath];
    };
    self.segmenters[task.taskId] = d;

    if (task.probed) {
        [d start]; // 已探测：直接续传 / 重新分段
    } else {
        [self probeTask:task];
    }
    [self.store save];
}

- (void)probeTask:(DLTask *)task {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:task.urlString]];
    req.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    [req setValue:@"bytes=0-0" forHTTPHeaderField:@"Range"];
    NSURLSessionDataTask *p = [self.foregroundSession dataTaskWithRequest:req];
    p.taskDescription = [task.taskId stringByAppendingString:kProbeSuffix];
    [p resume];
}

- (void)segmentedTaskFinished:(NSString *)taskId tmpPath:(NSString *)tmpPath {
    [self.lock lock];
    DLTask *t = [self.store taskWithId:taskId];
    if (t && t.state == DLTaskStateRunning) {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSDictionary *attr = [fm attributesOfItemAtPath:tmpPath error:nil];
        int64_t actual = [attr[NSFileSize] longLongValue];
        if (t.totalBytes > 0 && actual != t.totalBytes) {
            /* 分片拼完大小对不上（多半是某段没下完/续传错位）：报失败，
               别把坏文件塞进下载目录 */
            t.state = DLTaskStateFailed;
            t.errorMessage = [NSString stringWithFormat:@"文件大小不符（期望 %lld，实际 %lld）",
                              (long long)t.totalBytes, (long long)actual];
            t.speed = 0;
            [fm removeItemAtPath:tmpPath error:nil];
        } else {
            NSString *dest = [self.store.downloadsPath stringByAppendingPathComponent:t.fileName];
            dest = [self uniquePathFor:dest];
            NSError *err = nil;
            if ([fm moveItemAtPath:tmpPath toPath:dest error:&err]) {
                t.fileName = dest.lastPathComponent;
                t.state = DLTaskStateCompleted;
            } else {
                t.state = DLTaskStateFailed;
                t.errorMessage = err.localizedDescription ?: @"写入文件失败";
                [fm removeItemAtPath:tmpPath error:nil];
            }
        }
        if (t.state == DLTaskStateCompleted) {
            t.receivedBytes = t.totalBytes > 0 ? t.totalBytes : t.receivedBytes;
        }
        t.speed = 0;
        t.sessionTask = nil;
        t.updatedAt = [[NSDate date] timeIntervalSince1970];
        t.segments = nil;
    }
    [self.segmenters removeObjectForKey:taskId];
    [self.store save];
    [self.lock unlock];
    [self pump];
    [self notifyTasksChanged];
}

#pragma mark - NSURLSessionDataDelegate (分段 + 探测)

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
 didReceiveResponse:(NSURLResponse *)response
  completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    NSString *tag = dataTask.taskDescription;
    if ([tag hasSuffix:kProbeSuffix]) {
        NSString *taskId = [tag substringToIndex:tag.length - kProbeSuffix.length];
        if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
            [self handleProbeResponse:(NSHTTPURLResponse *)response forTaskId:taskId];
        }
    }
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    NSString *tag = dataTask.taskDescription;
    if ([tag hasSuffix:kProbeSuffix]) return; // 丢弃探测的 1 字节
    NSArray *parts = [tag componentsSeparatedByString:@"|"];
    if (parts.count != 2) return;
    NSString *taskId = parts[0];
    NSInteger idx = [parts[1] integerValue];

    [self.lock lock];
    DLSegmentDownloader *d = self.segmenters[taskId];
    [self.lock unlock];
    if (!d) return;

    [d receiveData:data atIndex:idx];

    [self.lock lock];
    DLTask *task = [self.store taskWithId:taskId];
    if (task) [self updateSpeedForTask:task];
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    BOOL shouldNotify = (now - self.lastProgressNotify >= 0.5);
    BOOL shouldSave = (now - self.lastSaveTime >= 2.0);
    if (shouldNotify) {
        self.lastProgressNotify = now;
        [d syncToTask];
    }
    if (shouldSave) {
        self.lastSaveTime = now;
        [self.store save];
    }
    [self.lock unlock];
    if (shouldNotify) [self notifyProgress];
}

- (void)handleProbeResponse:(NSHTTPURLResponse *)http forTaskId:(NSString *)taskId {
    [self.lock lock];
    DLTask *task = [self.store taskWithId:taskId];
    if (!task || task.state != DLTaskStateRunning) { [self.lock unlock]; return; }

    NSInteger code = http.statusCode;
    if (code == 206) {
        task.supportsRange = YES;
        task.totalBytes = [DLDownloadEngine totalFromContentRange:[self headerValue:@"Content-Range" in:http.allHeaderFields]
                                                        fallback:[[self headerValue:@"Content-Length" in:http.allHeaderFields] longLongValue]];
    } else if (code == 200) {
        task.supportsRange = NO;
        task.totalBytes = [[self headerValue:@"Content-Length" in:http.allHeaderFields] longLongValue];
    } else if ((code == 403 || code == 405 || code == 501) && task.mode == DLDownloadModeSegmented) {
        /* 分段探测被拒：有些防盗链站只放行「不带 Range 的整段请求」，
           退回后台整段模式再试一次，而不是直接判失败 */
        [self.segmenters removeObjectForKey:taskId];
        task.mode = DLDownloadModeBackground;
        task.probed = NO;
        task.supportsRange = NO;
        task.receivedBytes = 0;
        task.totalBytes = 0;
        task.errorMessage = nil;
        [self.store save];
        [self startBackgroundTask:task];
        [self.lock unlock];
        [self notifyTasksChanged];
        return;
    } else {
        task.errorMessage = [NSString stringWithFormat:@"HTTP %ld", (long)code];
        task.state = DLTaskStateFailed;
        task.sessionTask = nil;
        [self.segmenters removeObjectForKey:taskId];
        [self.store save];
        [self.lock unlock];
        [self notifyTasksChanged];
        [self pump];
        return;
    }
    task.probed = YES;
    DLSegmentDownloader *d = self.segmenters[taskId];
    [self.store save];
    [self.lock unlock];
    if (d) [d start];
}

#pragma mark - NSURLSessionDownloadDelegate (后台整段)

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    [self.lock lock];
    DLTask *task = [self.store taskWithId:downloadTask.taskDescription];
    if (task) {
        task.receivedBytes = task.baseBytes + totalBytesWritten;
        if (totalBytesExpectedToWrite > 0) {
            task.totalBytes = task.baseBytes + totalBytesExpectedToWrite;
        }
        task.updatedAt = [[NSDate date] timeIntervalSince1970];
        [self updateSpeedForTask:task];
    }
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    BOOL notify = (now - self.lastProgressNotify >= 0.5);
    BOOL shouldSave = (now - self.lastSaveTime >= 2.0);
    if (notify) {
        self.lastProgressNotify = now;
    }
    if (shouldSave) {
        self.lastSaveTime = now;
        [self.store save];
    }
    [self.lock unlock];
    if (notify) [self notifyProgress];
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location {
    [self.lock lock];
    DLTask *task = [self.store taskWithId:downloadTask.taskDescription];
    if (task) {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *dest = [self.store.downloadsPath stringByAppendingPathComponent:task.fileName];
        dest = [self uniquePathFor:dest];
        task.fileName = dest.lastPathComponent;

        NSError *err = nil;
        [fm removeItemAtPath:dest error:nil];
        if (![fm moveItemAtURL:location toURL:[NSURL fileURLWithPath:dest] error:&err]) {
            task.errorMessage = err.localizedDescription ?: @"写入文件失败";
            /* 落盘失败就别把进度标成 100%，否则看起来像「完成了但文件没有」 */
        } else {
            task.receivedBytes = task.totalBytes > 0 ? task.totalBytes : task.receivedBytes;
        }
    }
    [self.lock unlock];
}

#pragma mark - Task 完成（downloadTask + dataTask 共用）

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    NSString *tag = task.taskDescription;

    // 探测请求结束
    if ([tag hasSuffix:kProbeSuffix]) {
        NSString *taskId = [tag substringToIndex:tag.length - kProbeSuffix.length];
        [self.lock lock];
        DLTask *t = [self.store taskWithId:taskId];
        if (t && t.state == DLTaskStateRunning && !t.probed) {
            t.state = DLTaskStateFailed;
            t.errorMessage = error ? (error.localizedDescription ?: @"探测失败") : @"无法获取文件信息";
            t.sessionTask = nil;
            [self.segmenters removeObjectForKey:taskId];
            [self.store save];
            [self.lock unlock];
            [self notifyTasksChanged];
            [self pump];
        } else {
            [self.lock unlock];
        }
        return;
    }

    if ([task isKindOfClass:[NSURLSessionDownloadTask class]]) {
        [self handleBackgroundComplete:(NSURLSessionDownloadTask *)task error:error];
    } else if ([task isKindOfClass:[NSURLSessionDataTask class]]) {
        [self handleSegmentComplete:(NSURLSessionDataTask *)task error:error];
    }
}

- (void)handleBackgroundComplete:(NSURLSessionDownloadTask *)downloadTask error:(NSError *)error {
    [self.lock lock];
    DLTask *t = [self.store taskWithId:downloadTask.taskDescription];
    if (!t) { [self.lock unlock]; return; }

    if (t.cancelForPause) {
        [self.lock unlock]; // 暂停由 cancelByProducingResumeData 回调收尾
        return;
    }

    if (error) {
        if (error.code == NSURLErrorCancelled) { [self.lock unlock]; return; }
        t.state = DLTaskStateFailed;
        t.errorMessage = error.localizedDescription;
        t.sessionTask = nil;
        t.speed = 0;
    } else {
        if (t.errorMessage.length > 0) {
            t.state = DLTaskStateFailed;
        } else {
            t.state = DLTaskStateCompleted;
            if (t.totalBytes > 0) t.receivedBytes = t.totalBytes;
            [self.store deleteResumeDataForTask:t];
        }
        t.sessionTask = nil;
        t.speed = 0;
    }
    t.updatedAt = [[NSDate date] timeIntervalSince1970];
    [self.store save];
    [self.lock unlock];
    [self pump];
    [self notifyTasksChanged];
}

- (void)handleSegmentComplete:(NSURLSessionDataTask *)dataTask error:(NSError *)error {
    NSArray *parts = [dataTask.taskDescription componentsSeparatedByString:@"|"];
    if (parts.count != 2) return;
    NSString *taskId = parts[0];
    NSInteger idx = [parts[1] integerValue];

    [self.lock lock];
    DLTask *t = [self.store taskWithId:taskId];
    DLSegmentDownloader *d = self.segmenters[taskId];
    if (!t || !d || t.state != DLTaskStateRunning) { [self.lock unlock]; return; }

    if (error) {
        if (error.code == NSURLErrorCancelled) { [self.lock unlock]; return; } // 暂停/移除取消
        t.state = DLTaskStateFailed;
        t.errorMessage = error.localizedDescription ?: @"下载失败";
        t.speed = 0;
        t.sessionTask = nil;
        [d cancel];
        [d syncToTask]; // 保留已下载的分段进度供续传
        [self.segmenters removeObjectForKey:taskId];
        [self.store save];
        [self.lock unlock];
        [self pump];
        [self notifyTasksChanged];
        return;
    }

    [d segmentFinishedAtIndex:idx]; // 最后一段会触发 finish → segmentedTaskFinished
    [self.store save];
    [self.lock unlock];
}

- (void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session {
    void (^handler)(void) = self.backgroundSessionCompletionHandler;
    self.backgroundSessionCompletionHandler = nil;
    if (handler) {
        dispatch_async(dispatch_get_main_queue(), handler);
    }
}

#pragma mark - Helpers

- (void)updateSpeedForTask:(DLTask *)task {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (task.speedTime <= 0) {
        task.speedTime = now;
        task.speedBytes = task.receivedBytes;
        return;
    }
    double dt = now - task.speedTime;
    if (dt < 0.5) return;
    double inst = (double)(task.receivedBytes - task.speedBytes) / dt;
    if (inst < 0) inst = 0;
    /* 指数平滑：0.5s 窗口的瞬时差值抖得太厉害，看起来像虚标 */
    if (task.speed <= 0) task.speed = (int64_t)inst;
    else task.speed = (int64_t)((double)task.speed * 0.6 + inst * 0.4);
    task.speedTime = now;
    task.speedBytes = task.receivedBytes;
}

- (NSString *)headerValue:(NSString *)name in:(NSDictionary *)headers {
    for (NSString *k in headers) {
        if ([k caseInsensitiveCompare:name] == NSOrderedSame) {
            return headers[k];
        }
    }
    return nil;
}

+ (int64_t)totalFromContentRange:(NSString *)range fallback:(int64_t)fallback {
    if (range.length == 0) return fallback;
    NSRange slash = [range rangeOfString:@"/" options:NSBackwardsSearch];
    if (slash.location == NSNotFound) return fallback;
    NSString *totalStr = [range substringFromIndex:slash.location + 1];
    int64_t v = [totalStr longLongValue]; // "*" → 0
    return v > 0 ? v : fallback;
}

- (NSString *)uniquePathFor:(NSString *)path {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) return path;
    NSString *dir = path.stringByDeletingLastPathComponent;
    NSString *base = path.lastPathComponent.stringByDeletingPathExtension;
    NSString *ext = path.pathExtension;
    for (int i = 1; ; i++) {
        NSString *name = ext.length > 0
            ? [NSString stringWithFormat:@"%@ (%d).%@", base, i, ext]
            : [NSString stringWithFormat:@"%@ (%d)", base, i];
        NSString *cand = [dir stringByAppendingPathComponent:name];
        if (![fm fileExistsAtPath:cand]) return cand;
    }
}

+ (int64_t)bytesFromResumeData:(NSData *)data {
    id plist = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL];
    if ([plist isKindOfClass:[NSDictionary class]]) {
        NSNumber *n = plist[@"NSURLSessionResumeBytesReceived"];
        if (n) return n.longLongValue;
    }
    return 0;
}

#pragma mark - Notify

- (void)notifyTasksChanged {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:DLDownloadTasksChangedNotification object:nil];
    });
}

- (void)notifyProgress {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:DLDownloadProgressNotification object:nil];
    });
}

@end
