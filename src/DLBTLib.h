#import <Foundation/Foundation.h>

extern NSString *const DLBTTasksChangedNotification;

typedef NS_ENUM(NSInteger, DLBTTaskState) {
    DLBTTaskStateMetadata = 0,
    DLBTTaskStateChecking,
    DLBTTaskStateDownloading,
    DLBTTaskStateFinished,
    DLBTTaskStateSeeding,
    DLBTTaskStatePaused,
    DLBTTaskStateError,
};

@interface DLBTTask : NSObject
@property (nonatomic, copy) NSString *infoHash;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) DLBTTaskState state;
@property (nonatomic, copy) NSString *stateText;
@property (nonatomic, assign) double progress;          // 0..1
@property (nonatomic, assign) long long totalDone;
@property (nonatomic, assign) long long totalWanted;
@property (nonatomic, assign) double downloadRate;      // B/s
@property (nonatomic, assign) double uploadRate;        // B/s
@property (nonatomic, assign) NSInteger numPeers;
@property (nonatomic, assign) NSInteger numSeeds;
@property (nonatomic, copy) NSString *errorText;
@property (nonatomic, copy) NSString *magnetURI;
@end

/// libtorrent 2.0 封装（本模块是 iTorrent / LibTorrent-Swift 的 ObjC++ 精简移植）
@interface DLBTLib : NSObject

+ (instancetype)shared;

- (void)start;
- (BOOL)isStarted;

- (BOOL)addMagnet:(NSString *)uri error:(NSString **)error;
- (BOOL)addTorrentFile:(NSString *)path error:(NSString **)error;

- (NSArray<DLBTTask *> *)tasks;

- (void)pauseTask:(NSString *)infoHash;
- (void)resumeTask:(NSString *)infoHash;
- (void)removeTask:(NSString *)infoHash deleteFiles:(BOOL)deleteFiles;

- (void)setDownloadLimitKB:(NSInteger)down uploadLimitKB:(NSInteger)up;
- (void)setSeedingEnabled:(BOOL)enabled;

- (NSString *)downloadDirectory;
- (NSString *)versionString;

@end
