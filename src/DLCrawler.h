#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* 网页抓取：输入一个页面 URL，把页面里的可下载链接扒出来。
 * 纯 Foundation（正则解析），不依赖第三方库；静态抓不到时由 DLWebRenderer 兜底。 */

@interface DLCrawlItem : NSObject

@property (nonatomic, copy) NSString *urlString;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *ext;       // 小写、不带点，可能为空
@property (nonatomic, copy) NSString *category;  // 视频/音频/图片/压缩包/文档/种子/其他
@property (nonatomic, assign) BOOL crossDomain;  // 与页面不同域

@end

@interface DLCrawlOptions : NSObject

@property (nonatomic, assign) BOOL sameDomainOnly;   // 只保留同域链接
@property (nonatomic, assign) BOOL includeImages;    // 是否包含图片
@property (nonatomic, copy, nullable) NSArray<NSString *> *extensions; // 小写不带点，空=不过滤
@property (nonatomic, copy, nullable) NSString *keyword;               // 文件名/URL 包含
@property (nonatomic, copy, nullable) NSString *regex;                 // 对完整 URL 做正则
@property (nonatomic, assign) BOOL allowWebFallback; // 解析 0 条时用 WKWebView 再试一次（默认 YES）

@end

@interface DLCrawler : NSObject

/// 抓取并解析。completion 一定在主线程回调。
/// @param usedWebView 是否走了 WebView 兜底渲染
+ (void)crawlURLString:(NSString *)urlString
               options:(DLCrawlOptions *)options
            completion:(void (^)(NSArray<DLCrawlItem *> *items,
                                 NSString * _Nullable errorMessage,
                                 BOOL usedWebView))completion;

/// 纯解析（便于自检 / 复用）：把一段 HTML 按 baseURL 解析成条目。
+ (NSArray<DLCrawlItem *> *)parseHTML:(NSString *)html
                               baseURL:(NSURL *)baseURL
                               options:(DLCrawlOptions *)options;

@end

NS_ASSUME_NONNULL_END
