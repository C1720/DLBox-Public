#import "DLTask.h"

@implementation DLTask

- (instancetype)initWithURLString:(NSString *)urlString fileName:(NSString *)fileName {
    self = [super init];
    if (self) {
        _taskId = [[NSUUID UUID] UUIDString];
        _urlString = [urlString copy];
        _state = DLTaskStateWaiting;
        _mode = DLDownloadModeSegmented;
        _segmentCount = 4;
        _createdAt = [[NSDate date] timeIntervalSince1970];
        _updatedAt = _createdAt;
        if (fileName.length > 0) {
            _fileName = [fileName copy];
        } else {
            NSURL *u = [NSURL URLWithString:urlString];
            NSString *p = u.lastPathComponent;
            _fileName = p.length > 0 ? p : _taskId;
        }
    }
    return self;
}

- (NSDictionary *)dictionaryRepresentation {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"id"] = self.taskId;
    d[@"url"] = self.urlString;
    d[@"file"] = self.fileName;
    d[@"state"] = @(self.state);
    d[@"total"] = @(self.totalBytes);
    d[@"received"] = @(self.receivedBytes);
    if (self.errorMessage.length > 0) d[@"error"] = self.errorMessage;
    d[@"created"] = @(self.createdAt);
    d[@"updated"] = @(self.updatedAt);
    d[@"mode"] = @(self.mode);
    d[@"segcount"] = @(self.segmentCount);
    d[@"range"] = @(self.supportsRange);
    d[@"probed"] = @(self.probed);
    if (self.segments.count > 0) d[@"segments"] = self.segments;
    return d;
}

+ (instancetype)taskFromDictionary:(NSDictionary *)dict {
    NSString *url = dict[@"url"];
    if (![url isKindOfClass:[NSString class]] || url.length == 0) return nil;
    DLTask *t = [[DLTask alloc] initWithURLString:url fileName:dict[@"file"]];
    t.taskId = dict[@"id"] ?: t.taskId;
    t.state = (DLTaskState)[dict[@"state"] integerValue];
    t.totalBytes = [dict[@"total"] longLongValue];
    t.receivedBytes = [dict[@"received"] longLongValue];
    t.errorMessage = dict[@"error"];
    t.createdAt = [dict[@"created"] doubleValue];
    t.updatedAt = [dict[@"updated"] doubleValue];
    t.mode = (DLDownloadMode)[dict[@"mode"] integerValue];
    t.segmentCount = [dict[@"segcount"] integerValue];
    if (t.segmentCount <= 0) t.segmentCount = 4;
    t.supportsRange = [dict[@"range"] boolValue];
    t.probed = [dict[@"probed"] boolValue];
    id seg = dict[@"segments"];
    if ([seg isKindOfClass:[NSArray class]]) t.segments = seg;
    return t;
}

- (NSString *)stateName {
    switch (self.state) {
        case DLTaskStateWaiting:   return @"等待中";
        case DLTaskStateRunning:   return @"下载中";
        case DLTaskStatePaused:    return @"已暂停";
        case DLTaskStateCompleted: return @"已完成";
        case DLTaskStateFailed:    return @"失败";
    }
    return @"";
}

- (NSString *)modeName {
    return self.mode == DLDownloadModeBackground ? @"后台整段" : @"分段加速";
}

- (double)progress {
    if (self.totalBytes <= 0) return 0.0;
    double p = (double)self.receivedBytes / (double)self.totalBytes;
    if (p < 0.0) p = 0.0;
    if (p > 1.0) p = 1.0;
    return p;
}

@end
