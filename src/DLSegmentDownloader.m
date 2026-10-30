#import "DLSegmentDownloader.h"
#import "DLTask.h"
#import "DLRateLimiter.h"

@implementation DLSegmentDownloader {
    DLTask *_task;
    NSURLSession *_session;
    NSString *_partDir;
    NSString *_destPath;
    DLRateLimiter *_limiter;
    NSMutableArray<NSMutableDictionary *> *_segs;
    NSInteger _finishedCount;
}

- (instancetype)initWithTask:(DLTask *)task
                     session:(NSURLSession *)session
                     partDir:(NSString *)partDir
                    destPath:(NSString *)destPath
                 rateLimiter:(DLRateLimiter *)rateLimiter {
    self = [super init];
    if (self) {
        _task = task;
        _session = session;
        _partDir = [partDir copy];
        _destPath = [destPath copy];
        _limiter = rateLimiter;
        _segs = [NSMutableArray array];
        _finishedCount = 0;
    }
    return self;
}

- (NSString *)partPathForIndex:(NSInteger)i {
    return [_partDir stringByAppendingPathComponent:[NSString stringWithFormat:@"part-%ld", (long)i]];
}

- (void)start {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:_partDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSInteger n = _task.segmentCount > 0 ? _task.segmentCount : 1;
    NSArray *saved = _task.segments;

    // 未知大小：单段流式，无 Range
    if (_task.totalBytes <= 0) {
        NSMutableDictionary *seg = [NSMutableDictionary dictionary];
        seg[@"start"] = @0;
        seg[@"end"] = @(-1); // 未知
        seg[@"done"] = @0;
        _segs = [NSMutableArray arrayWithObject:seg];
        _task.segments = @[@{@"start":@0, @"end":@(-1), @"done":@0}];
        _task.segmentCount = 1;
    } else if (saved.count > 0) {
        for (NSDictionary *d in saved) {
            [_segs addObject:[d mutableCopy]];
        }
    } else {
        if (!_task.supportsRange || n <= 1) n = 1;
        int64_t total = _task.totalBytes;
        if (n > total) n = (NSInteger)MAX(1, total);
        int64_t segSize = total / n;
        for (NSInteger i = 0; i < n; i++) {
            int64_t start = i * segSize;
            int64_t end = (i == n - 1) ? (total - 1) : ((i + 1) * segSize - 1);
            if (end < start) end = start;
            NSMutableDictionary *seg = [NSMutableDictionary dictionary];
            seg[@"start"] = @(start);
            seg[@"end"] = @(end);
            seg[@"done"] = @0;
            [_segs addObject:seg];
        }
        [self syncToTask];
    }

    // 逐段创建 dataTask（以 part 文件实际大小作为已下载量，保证续传一致性）
    int64_t actualSum = 0;
    for (NSInteger i = 0; i < (NSInteger)_segs.count; i++) {
        NSMutableDictionary *seg = _segs[i];
        int64_t start = [seg[@"start"] longLongValue];
        int64_t end = [seg[@"end"] longLongValue];
        int64_t size = end < 0 ? INT64_MAX : (end - start + 1);

        NSString *part = [self partPathForIndex:i];
        if (![fm fileExistsAtPath:part]) {
            [fm createFileAtPath:part contents:nil attributes:nil];
        }
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:part];
        int64_t done = (int64_t)[fh seekToEndOfFile];
        seg[@"fh"] = fh;
        seg[@"done"] = @(done);
        actualSum += done;

        if (end >= 0 && done >= size) {
            [fh closeFile];
            seg[@"fh"] = [NSNull null];
            _finishedCount++;
            continue;
        }

        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:_task.urlString]];
        req.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        if (_task.supportsRange && end >= 0) {
            [req setValue:[NSString stringWithFormat:@"bytes=%lld-%lld", start + done, end]
                forHTTPHeaderField:@"Range"];
        }
        NSURLSessionDataTask *dt = [_session dataTaskWithRequest:req];
        dt.taskDescription = [NSString stringWithFormat:@"%@|%ld", _task.taskId, (long)i];
        seg[@"task"] = dt;
        [dt resume];
    }

    if ((NSInteger)_segs.count > 0 && _finishedCount >= (NSInteger)_segs.count) {
        [self finish];
    } else if (saved.count > 0) {
        /* 续传：以 part 文件实际大小重算已下载量，否则进度条和实际对不上 */
        _task.receivedBytes = actualSum;
        [self syncToTask];
    }
}

- (void)receiveData:(NSData *)data atIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)_segs.count) return;
    if (data.length == 0) return;
    [_limiter consume:(int64_t)data.length];

    NSMutableDictionary *seg = _segs[index];
    id fh = seg[@"fh"];
    if (fh && fh != (id)[NSNull null]) {
        [fh writeData:data];
    }
    int64_t done = [seg[@"done"] longLongValue] + (int64_t)data.length;
    seg[@"done"] = @(done);
    _task.receivedBytes += (int64_t)data.length;
    _task.updatedAt = [[NSDate date] timeIntervalSince1970];
}

- (void)segmentFinishedAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)_segs.count) return;
    NSMutableDictionary *seg = _segs[index];
    id fh = seg[@"fh"];
    if (fh && fh != (id)[NSNull null]) {
        [fh closeFile];
        seg[@"fh"] = [NSNull null];
    }
    int64_t start = [seg[@"start"] longLongValue];
    int64_t end = [seg[@"end"] longLongValue];
    if (end >= 0) {
        seg[@"done"] = @(end - start + 1);
    }
    _finishedCount++;
    if (_finishedCount >= (NSInteger)_segs.count) {
        [self finish];
    }
}

- (void)finish {
    NSFileManager *fm = [NSFileManager defaultManager];
    /* 目标文件可能存在（上次崩溃残留）。createFileAtPath 对已存在文件不截断，
       直接写会追加到旧内容后面 → 「完成」但文件损坏，所以先删。 */
    [fm removeItemAtPath:_destPath error:nil];
    [fm createFileAtPath:_destPath contents:nil attributes:nil];
    NSFileHandle *out = [NSFileHandle fileHandleForWritingAtPath:_destPath];

    /* 流式拼接：按 1 MB 块搬运，避免把整个分段读进内存（4 GB ISO × 8 段
       会一次占 500 MB，iOS 上直接被 jetsam 杀掉）。 */
    const NSUInteger kChunk = 1024 * 1024;
    int64_t written = 0;
    BOOL writeFailed = NO;
    for (NSInteger i = 0; i < (NSInteger)_segs.count && out && !writeFailed; i++) {
        NSFileHandle *in = [NSFileHandle fileHandleForReadingAtPath:[self partPathForIndex:i]];
        if (!in) continue;
        while (YES) {
            @autoreleasepool {
                NSError *rerr = nil;
                NSData *chunk = [in readDataUpToLength:kChunk error:&rerr];
                if (!chunk || chunk.length == 0) break;
                @try {
                    [out writeData:chunk];
                } @catch (NSException *e) {
                    writeFailed = YES;
                }
                if (writeFailed) break;
                written += (int64_t)chunk.length;
            }
        }
        [in closeFile];
    }
    [out closeFile];

    [fm removeItemAtPath:_partDir error:nil];
    _task.receivedBytes = _task.totalBytes > 0 ? _task.totalBytes : written;
    _task.totalBytes = _task.totalBytes > 0 ? _task.totalBytes : written;
    if (writeFailed) {
        [fm removeItemAtPath:_destPath error:nil];
        return; /* 交给上层按超时/失败处理 */
    }
    if (self.onFinished) self.onFinished(_destPath);
}

- (void)cancel {
    for (NSMutableDictionary *seg in _segs) {
        id t = seg[@"task"];
        if (t && t != (id)[NSNull null]) [t cancel];
        id fh = seg[@"fh"];
        if (fh && fh != (id)[NSNull null]) [fh closeFile];
    }
}

- (void)syncToTask {
    NSMutableArray *arr = [NSMutableArray arrayWithCapacity:_segs.count];
    for (NSMutableDictionary *seg in _segs) {
        [arr addObject:@{
            @"start": seg[@"start"],
            @"end": seg[@"end"],
            @"done": seg[@"done"],
        }];
    }
    _task.segments = arr;
    _task.segmentCount = (NSInteger)arr.count;
}

- (NSInteger)segmentCount {
    return (NSInteger)_segs.count;
}

@end
