#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* 兜底渲染器：静态 HTML 抓不到链接时，用隐藏的 WKWebView 把页面真正渲染一遍，
 * 再取 document.documentElement.outerHTML 交给 DLCrawler 解析。
 * 只在主线程调用；内部自己管生命周期，用完即弃。 */
@interface DLWebRenderer : NSObject

+ (void)renderURLString:(NSString *)urlString
                timeout:(NSTimeInterval)timeout
             completion:(void (^)(NSString * _Nullable html, NSString * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
