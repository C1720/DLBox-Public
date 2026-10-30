#import <Foundation/Foundation.h>

@class DLTask;

NS_ASSUME_NONNULL_BEGIN

@interface DLTaskStore : NSObject

@property (nonatomic, strong) NSMutableArray<DLTask *> *tasks;

- (instancetype)initWithRootPath:(NSString *)rootPath;

- (void)load;
- (void)save;

- (nullable DLTask *)taskWithId:(NSString *)taskId;
- (void)insertTask:(DLTask *)task;
- (void)removeTask:(DLTask *)task;

- (NSString *)downloadsPath;

// 断点续传（background 模式）
- (NSString *)resumeDataPathForTask:(DLTask *)task;
- (void)saveResumeData:(NSData *)data forTask:(DLTask *)task;
- (nullable NSData *)loadResumeDataForTask:(DLTask *)task;
- (void)deleteResumeDataForTask:(DLTask *)task;

// 分段下载（segmented 模式）
- (NSString *)partsPath;
- (NSString *)partDirForTask:(DLTask *)task;
- (void)deletePartDirForTask:(DLTask *)task;

@end

NS_ASSUME_NONNULL_END
