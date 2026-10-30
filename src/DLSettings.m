#import "DLSettings.h"

static NSString * const kMaxConcurrent = @"dl.settings.maxConcurrent";
static NSString * const kSegmentCount  = @"dl.settings.segmentCount";
static NSString * const kRateLimit     = @"dl.settings.rateLimitKBs";
static NSString * const kAllowHTTP     = @"dl.settings.allowHTTP";
static NSString * const kDownloadMode  = @"dl.settings.downloadMode";

@implementation DLSettings

+ (instancetype)shared {
    static DLSettings *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[DLSettings alloc] init]; });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSDictionary *def = @{
            kMaxConcurrent: @2,
            kSegmentCount:  @4,
            kRateLimit:     @0,
            kAllowHTTP:     @YES,
            kDownloadMode:  @0,
        };
        [[NSUserDefaults standardUserDefaults] registerDefaults:def];
    }
    return self;
}

- (NSInteger)maxConcurrent {
    return [[NSUserDefaults standardUserDefaults] integerForKey:kMaxConcurrent];
}
- (void)setMaxConcurrent:(NSInteger)v {
    [[NSUserDefaults standardUserDefaults] setInteger:v forKey:kMaxConcurrent];
}

- (NSInteger)segmentCount {
    return [[NSUserDefaults standardUserDefaults] integerForKey:kSegmentCount];
}
- (void)setSegmentCount:(NSInteger)v {
    [[NSUserDefaults standardUserDefaults] setInteger:v forKey:kSegmentCount];
}

- (NSInteger)rateLimitKBs {
    return [[NSUserDefaults standardUserDefaults] integerForKey:kRateLimit];
}
- (void)setRateLimitKBs:(NSInteger)v {
    [[NSUserDefaults standardUserDefaults] setInteger:v forKey:kRateLimit];
}

- (BOOL)allowHTTP {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kAllowHTTP];
}
- (void)setAllowHTTP:(BOOL)v {
    [[NSUserDefaults standardUserDefaults] setBool:v forKey:kAllowHTTP];
}

- (NSInteger)downloadMode {
    return [[NSUserDefaults standardUserDefaults] integerForKey:kDownloadMode];
}
- (void)setDownloadMode:(NSInteger)v {
    [[NSUserDefaults standardUserDefaults] setInteger:v forKey:kDownloadMode];
}

@end
