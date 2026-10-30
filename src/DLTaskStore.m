#import "DLTaskStore.h"
#import "DLTask.h"

@implementation DLTaskStore {
    NSString *_rootPath;
    NSString *_plistPath;
    NSMutableDictionary<NSString *, DLTask *> *_index; // taskId → task，避免每次线性扫描
}

- (instancetype)initWithRootPath:(NSString *)rootPath {
    self = [super init];
    if (self) {
        _rootPath = [rootPath copy];
        _plistPath = [rootPath stringByAppendingPathComponent:@"tasks.plist"];
        _tasks = [NSMutableArray array];
        _index = [NSMutableDictionary dictionary];
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:rootPath withIntermediateDirectories:YES attributes:nil error:nil];
        [fm createDirectoryAtPath:[self downloadsPath] withIntermediateDirectories:YES attributes:nil error:nil];
        [fm createDirectoryAtPath:[self partsPath] withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return self;
}

- (NSString *)downloadsPath {
    return [_rootPath stringByAppendingPathComponent:@"downloads"];
}

- (NSString *)partsPath {
    return [_rootPath stringByAppendingPathComponent:@"parts"];
}

- (NSString *)partDirForTask:(DLTask *)task {
    return [[self partsPath] stringByAppendingPathComponent:task.taskId];
}

- (void)deletePartDirForTask:(DLTask *)task {
    [[NSFileManager defaultManager] removeItemAtPath:[self partDirForTask:task] error:nil];
}

- (void)load {
    NSArray *arr = [NSArray arrayWithContentsOfFile:_plistPath];
    [_tasks removeAllObjects];
    [_index removeAllObjects];
    if ([arr isKindOfClass:[NSArray class]]) {
        for (NSDictionary *d in arr) {
            if (![d isKindOfClass:[NSDictionary class]]) continue;
            DLTask *t = [DLTask taskFromDictionary:d];
            if (t) {
                [_tasks addObject:t];
                if (t.taskId.length) _index[t.taskId] = t;
            }
        }
    }
}

- (void)save {
    NSMutableArray *arr = [NSMutableArray arrayWithCapacity:self.tasks.count];
    for (DLTask *t in self.tasks) {
        [arr addObject:[t dictionaryRepresentation]];
    }
    [arr writeToFile:_plistPath atomically:YES];
}

- (DLTask *)taskWithId:(NSString *)taskId {
    if (taskId.length == 0) return nil;
    return _index[taskId];
}

- (void)insertTask:(DLTask *)task {
    [self.tasks insertObject:task atIndex:0];
    if (task.taskId.length) _index[task.taskId] = task;
}

- (void)removeTask:(DLTask *)task {
    [self.tasks removeObject:task];
    if (task.taskId.length) [_index removeObjectForKey:task.taskId];
}

- (NSString *)resumeDataPathForTask:(DLTask *)task {
    return [_rootPath stringByAppendingPathComponent:[task.taskId stringByAppendingString:@".resume"]];
}

- (void)saveResumeData:(NSData *)data forTask:(DLTask *)task {
    [data writeToFile:[self resumeDataPathForTask:task] atomically:YES];
}

- (NSData *)loadResumeDataForTask:(DLTask *)task {
    return [NSData dataWithContentsOfFile:[self resumeDataPathForTask:task]];
}

- (void)deleteResumeDataForTask:(DLTask *)task {
    [[NSFileManager defaultManager] removeItemAtPath:[self resumeDataPathForTask:task] error:nil];
}

@end
