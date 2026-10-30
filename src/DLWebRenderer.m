#import "DLWebRenderer.h"
#import <WebKit/WebKit.h>
#import <UIKit/UIKit.h>
#import "DLLog.h"

#pragma mark - 单个渲染任务

@interface _DLWebRenderTask : NSObject <WKNavigationDelegate>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, copy) void (^completion)(NSString *, NSString *);
@property (nonatomic, assign) BOOL done;
@end

static NSMutableSet<_DLWebRenderTask *> *DLActiveTasks(void);

@implementation _DLWebRenderTask

- (void)finishWithHTML:(NSString *)html error:(NSString *)error {
    if (self.done) return;
    self.done = YES;
    [self.webView stopLoading];
    self.webView.navigationDelegate = nil;
    [self.webView removeFromSuperview];
    self.webView = nil;
    [DLActiveTasks() removeObject:self];
    void (^cb)(NSString *, NSString *) = self.completion;
    self.completion = nil;
    if (cb) cb(html, error);
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    [webView evaluateJavaScript:@"document.documentElement.outerHTML"
             completionHandler:^(id result, NSError *error) {
        if (error || ![result isKindOfClass:[NSString class]] || [(NSString *)result length] == 0) {
            [self finishWithHTML:nil error:error.localizedDescription ?: @"WebView 取不到页面内容"];
        } else {
            [self finishWithHTML:(NSString *)result error:nil];
        }
    }];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self finishWithHTML:nil error:error.localizedDescription];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self finishWithHTML:nil error:error.localizedDescription];
}

@end

#pragma mark - DLWebRenderer

static NSMutableSet<_DLWebRenderTask *> *DLActiveTasks(void) {
    static NSMutableSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ set = [NSMutableSet set]; });
    return set;
}

@implementation DLWebRenderer

+ (void)renderURLString:(NSString *)urlString
                timeout:(NSTimeInterval)timeout
             completion:(void (^)(NSString *, NSString *))completion {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url || url.host.length == 0) {
        if (completion) completion(nil, @"链接格式不对");
        return;
    }
    if (timeout <= 0) timeout = 25;

    dispatch_async(dispatch_get_main_queue(), ^{
        _DLWebRenderTask *task = [[_DLWebRenderTask alloc] init];
        task.completion = completion;

        WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
        if (@available(iOS 14.0, *)) {
            cfg.defaultWebpagePreferences.allowsContentJavaScript = YES;
        }
        WKWebView *wv = [[WKWebView alloc] initWithFrame:CGRectMake(0, 0, 390, 844) configuration:cfg];
        wv.navigationDelegate = task;
        wv.customUserAgent = @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15";
        task.webView = wv;

        /* 挂到一个几乎透明的容器里，保证 WebKit 正常走渲染管线；用户看不见 */
        UIWindow *window = nil;
        for (UIWindow *w in UIApplication.sharedApplication.windows) {
            if (!w.hidden) { window = w; break; }
        }
        if (!window) window = UIApplication.sharedApplication.keyWindow;
        if (window) {
            UIView *host = [[UIView alloc] initWithFrame:CGRectMake(-4000, -4000, 390, 844)];
            host.userInteractionEnabled = NO;
            host.alpha = 0.01;
            [window addSubview:host];
            [host addSubview:wv];
            task.webView.accessibilityElementsHidden = YES;
        }

        [DLActiveTasks() addObject:task];
        [DLLog write:[NSString stringWithFormat:@"[Crawl] WebView 加载 %@", urlString]];

        NSURLRequest *req = [NSURLRequest requestWithURL:url
                                             cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                         timeoutInterval:timeout];
        [wv loadRequest:req];

        __weak _DLWebRenderTask *weakTask = task;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((timeout + 2) * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            _DLWebRenderTask *strongTask = weakTask;
            if (strongTask && !strongTask.done) {
                [strongTask finishWithHTML:nil error:@"WebView 渲染超时"];
                [DLActiveTasks() removeObject:strongTask];
            }
        });
    });
}

@end
