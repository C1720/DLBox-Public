#import "DLCrawler.h"
#import "DLWebRenderer.h"
#import "DLLog.h"

@implementation DLCrawlItem
- (NSString *)description {
    return [NSString stringWithFormat:@"<%@ %@ [%@]>", self.category, self.name, self.ext];
}
@end

@implementation DLCrawlOptions
- (instancetype)init {
    self = [super init];
    if (self) {
        _sameDomainOnly = NO;
        _includeImages = NO;
        _allowWebFallback = YES;
    }
    return self;
}
@end

#pragma mark - 分类表

static NSDictionary<NSString *, NSString *> *DLCategoryMap(void) {
    static NSDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            // 视频
            @"mp4": @"视频", @"mkv": @"视频", @"avi": @"视频", @"mov": @"视频", @"flv": @"视频",
            @"wmv": @"视频", @"webm": @"视频", @"m4v": @"视频", @"ts": @"视频", @"mpg": @"视频",
            @"mpeg": @"视频", @"3gp": @"视频", @"rmvb": @"视频", @"rm": @"视频", @"m3u8": @"视频",
            // 音频
            @"mp3": @"音频", @"flac": @"音频", @"wav": @"音频", @"aac": @"音频", @"m4a": @"音频",
            @"ogg": @"音频", @"opus": @"音频", @"wma": @"音频", @"ape": @"音频", @"alac": @"音频",
            // 图片
            @"jpg": @"图片", @"jpeg": @"图片", @"png": @"图片", @"gif": @"图片", @"webp": @"图片",
            @"bmp": @"图片", @"heic": @"图片", @"svg": @"图片", @"tiff": @"图片", @"avif": @"图片",
            // 压缩包 / 镜像
            @"zip": @"压缩包", @"rar": @"压缩包", @"7z": @"压缩包", @"tar": @"压缩包", @"gz": @"压缩包",
            @"bz2": @"压缩包", @"xz": @"压缩包", @"tgz": @"压缩包", @"iso": @"压缩包", @"dmg": @"压缩包",
            // 文档
            @"pdf": @"文档", @"doc": @"文档", @"docx": @"文档", @"xls": @"文档", @"xlsx": @"文档",
            @"ppt": @"文档", @"pptx": @"文档", @"txt": @"文档", @"epub": @"文档", @"mobi": @"文档",
            @"azw3": @"文档", @"srt": @"文档", @"ass": @"文档",
            // 种子
            @"torrent": @"种子",
        };
    });
    return map;
}

static NSArray<NSString *> *DLCategoryOrder(void) {
    return @[@"视频", @"音频", @"压缩包", @"文档", @"种子", @"图片", @"其他"];
}

#pragma mark - DLCrawler

@interface DLCrawler ()
+ (BOOL)isDirSortQuery:(NSString *)query;
+ (BOOL)isSkipAssetExtension:(NSString *)ext;
+ (void)fetchHTML:(NSURL *)url
          uaIndex:(NSUInteger)uaIndex
          options:(DLCrawlOptions *)options
       completion:(void (^)(NSString *html, NSInteger code, NSError *error))done;
@end

static NSArray<NSString *> *DLUserAgents(void) {
    static NSArray *uas;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        uas = @[
            /* 1) 普通网页：完整 Safari UA，多数站点会返回桌面版完整 HTML */
            @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            /* 2) 兜底：部分镜像站 CDN 的 WAF 会拦 WebKit 系 UA（实测清华 TUNA 对 Safari UA 回 403，
                  对 curl / 自定义 UA 放行），这里自报家门重试一次 */
            @"DLBox/0.5.2 (iPhone; iOS; +https://github.com/C1720/DLBox-Public)",
        ];
    });
    return uas;
}

@implementation DLCrawler

+ (void)crawlURLString:(NSString *)urlString
               options:(DLCrawlOptions *)options
            completion:(void (^)(NSArray<DLCrawlItem *> *, NSString *, BOOL))completion {
    NSString *trimmed = [urlString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) {
        completion(@[], @"链接是空的", NO);
        return;
    }
    if (![trimmed.lowercaseString hasPrefix:@"http://"] && ![trimmed.lowercaseString hasPrefix:@"https://"]) {
        trimmed = [@"https://" stringByAppendingString:trimmed];
    }
    NSURL *url = [NSURL URLWithString:trimmed];
    if (!url || url.host.length == 0) {
        completion(@[], @"链接格式不对", NO);
        return;
    }
    if (!options) options = [[DLCrawlOptions alloc] init];

    [DLLog write:[NSString stringWithFormat:@"[Crawl] 开始抓取 %@", url.absoluteString]];

    [self fetchHTML:url uaIndex:0 options:options completion:^(NSString *html, NSInteger code, NSError *error) {
        NSArray<DLCrawlItem *> *items = html.length ? [self parseHTML:html baseURL:url options:options] : @[];
        [DLLog write:[NSString stringWithFormat:@"[Crawl] 静态抓取 HTTP %ld，HTML %lu 字符，解析 %lu 条",
                      (long)code, (unsigned long)html.length, (unsigned long)items.count]];

        BOOL needFallback = options.allowWebFallback && items.count == 0;
        if (!needFallback) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSString *err = nil;
                if (items.count == 0) {
                    err = error ? error.localizedDescription
                                : [NSString stringWithFormat:@"页面里没找到可下载链接（HTTP %ld）", (long)code];
                }
                completion(items, err, NO);
            });
            return;
        }

        [DLLog write:@"[Crawl] 静态解析 0 条，回退 WKWebView 渲染"];
        [DLWebRenderer renderURLString:url.absoluteString timeout:25 completion:^(NSString *renderedHTML, NSString *renderError) {
            NSArray<DLCrawlItem *> *items2 = renderedHTML.length ? [self parseHTML:renderedHTML baseURL:url options:options] : @[];
            [DLLog write:[NSString stringWithFormat:@"[Crawl] WebView 兜底解析 %lu 条", (unsigned long)items2.count]];
            dispatch_async(dispatch_get_main_queue(), ^{
                NSString *err = nil;
                if (items2.count == 0) {
                    err = renderError.length ? renderError
                        : (error.localizedDescription.length ? error.localizedDescription
                                                             : @"这个页面里没找到可下载链接（静态 + 渲染都试过了）");
                }
                completion(items2, err, YES);
            });
        }];
    }];
}

/// 带 UA 重试的 HTTP 拉取。blocked（403/406/429/451）时自动换下一套 UA。
+ (void)fetchHTML:(NSURL *)url
          uaIndex:(NSUInteger)uaIndex
          options:(DLCrawlOptions *)options
       completion:(void (^)(NSString *html, NSInteger code, NSError *error))done {
    NSArray<NSString *> *uas = DLUserAgents();
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 20;
    req.HTTPMethod = @"GET";
    req.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    if (uaIndex < uas.count) {
        [req setValue:uas[uaIndex] forHTTPHeaderField:@"User-Agent"];
    }
    [req setValue:@"text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
        forHTTPHeaderField:@"Accept"];
    [req setValue:@"zh-CN,zh;q=0.9,en;q=0.8" forHTTPHeaderField:@"Accept-Language"];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger code = 0;
        if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
            code = [(NSHTTPURLResponse *)response statusCode];
        }
        BOOL blocked = (code == 403 || code == 406 || code == 429 || code == 451);
        if (blocked && uaIndex + 1 < uas.count) {
            [DLLog write:[NSString stringWithFormat:@"[Crawl] HTTP %ld，换第 %lu 套 UA 重试",
                          (long)code, (unsigned long)(uaIndex + 2)]];
            [self fetchHTML:url uaIndex:uaIndex + 1 options:options completion:done];
            return;
        }
        NSString *html = nil;
        if (!error && code > 0 && code < 400 && data.length > 0) {
            html = [self stringFromData:data];
        }
        done(html, code, error);
    }];
    /* 关键：dataTask 创建后是 suspended 状态，不 resume 请求永远不发出，
       界面会一直停在「抓取中…」——这是 P5 抓取页点不动的根因。 */
    [task resume];
}

+ (NSString *)stringFromData:(NSData *)data {
    if (data.length == 0) return nil;
    NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (s) return s;
    /* 国内老站点常见 GBK / GB18030 */
    NSStringEncoding gb = CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000);
    s = [[NSString alloc] initWithData:data encoding:gb];
    if (s) return s;
    return [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
}

+ (NSArray<DLCrawlItem *> *)parseHTML:(NSString *)html
                               baseURL:(NSURL *)baseURL
                               options:(DLCrawlOptions *)options {
    if (html.length == 0) return @[];
    if (!options) options = [[DLCrawlOptions alloc] init];
    if (html.length > 5 * 1024 * 1024) html = [html substringToIndex:5 * 1024 * 1024];

    NSURL *effectiveBase = [self baseURLFromHTML:html fallback:baseURL];

    NSRegularExpression *linkRe = [NSRegularExpression
        regularExpressionWithPattern:@"(?i)(?:href|src|data-src|data-original|data-url)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')"
                             options:0 error:nil];
    NSRegularExpression *userRe = nil;
    if (options.regex.length) {
        userRe = [NSRegularExpression regularExpressionWithPattern:options.regex options:NSRegularExpressionCaseInsensitive error:nil];
    }

    NSMutableArray<DLCrawlItem *> *result = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSString *baseHost = [self normalizedHost:effectiveBase.host];
    NSString *keyword = [options.keyword stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSSet<NSString *> *extFilter = nil;
    if (options.extensions.count) {
        NSMutableSet *s = [NSMutableSet set];
        for (NSString *e in options.extensions) {
            NSString *v = [[e stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
            v = [v stringByReplacingOccurrencesOfString:@"." withString:@""];
            if (v.length) [s addObject:v];
        }
        if (s.count) extFilter = s;
    }

    NSArray<NSTextCheckingResult *> *matches = [linkRe matchesInString:html options:0 range:NSMakeRange(0, html.length)];
    for (NSTextCheckingResult *m in matches) {
        NSString *raw = nil;
        if ([m rangeAtIndex:1].location != NSNotFound) raw = [html substringWithRange:[m rangeAtIndex:1]];
        else if ([m rangeAtIndex:2].location != NSNotFound) raw = [html substringWithRange:[m rangeAtIndex:2]];
        if (raw.length == 0) continue;

        raw = [[self decodeHTMLEntities:raw] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (raw.length == 0) continue;

        NSString *lower = raw.lowercaseString;
        if ([lower hasPrefix:@"javascript:"] || [lower hasPrefix:@"mailto:"] ||
            [lower hasPrefix:@"tel:"] || [lower hasPrefix:@"data:"] || [lower hasPrefix:@"#"]) {
            continue;
        }

        NSURL *abs = [NSURL URLWithString:raw relativeToURL:effectiveBase];
        if (!abs) continue;
        abs = [NSURL URLWithString:abs.absoluteString]; // 规范化
        NSString *scheme = abs.scheme.lowercaseString;
        if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) continue;
        if (abs.host.length == 0) continue;

        /* 去掉 fragment */
        NSString *absolute = abs.absoluteString;
        NSRange hash = [absolute rangeOfString:@"#"];
        if (hash.location != NSNotFound) absolute = [absolute substringToIndex:hash.location];
        if (absolute.length == 0) continue;
        if ([seen containsObject:absolute]) continue;

        NSString *path = abs.path ?: @"";
        /* 目录链接（路径以 / 结尾）、上级目录不是文件，跳过；
           Apache/nginx 的排序参数 ?C=N;O=D 也不是文件 */
        if (path.length == 0 || [path hasSuffix:@"/"]) continue;
        if (abs.query.length && [DLCrawler isDirSortQuery:abs.query]) continue;

        NSString *ext = abs.pathExtension.lowercaseString ?: @"";
        /* 页面自身的 css/js/字体/图标不是下载目标，否则结果里全是噪音 */
        if ([DLCrawler isSkipAssetExtension:ext]) continue;

        NSString *category = DLCategoryMap()[ext] ?: @"其他";
        if ([category isEqualToString:@"图片"] && !options.includeImages) continue;
        if (extFilter && ![extFilter containsObject:ext]) continue;

        NSString *name = [self displayNameForURL:abs];
        if (keyword.length) {
            NSRange r1 = [name rangeOfString:keyword options:NSCaseInsensitiveSearch];
            NSRange r2 = [absolute rangeOfString:keyword options:NSCaseInsensitiveSearch];
            if (r1.location == NSNotFound && r2.location == NSNotFound) continue;
        }
        if (userRe && [userRe numberOfMatchesInString:absolute options:0 range:NSMakeRange(0, absolute.length)] == 0) continue;

        NSString *itemHost = [self normalizedHost:abs.host];
        BOOL cross = ![itemHost isEqualToString:baseHost];
        if (options.sameDomainOnly && cross) continue;

        DLCrawlItem *item = [[DLCrawlItem alloc] init];
        item.urlString = absolute;
        item.name = name;
        item.ext = ext ?: @"";
        item.category = category;
        item.crossDomain = cross;
        [result addObject:item];
        [seen addObject:absolute];
    }

    [result sortUsingComparator:^NSComparisonResult(DLCrawlItem *a, DLCrawlItem *b) {
        NSUInteger ia = [DLCategoryOrder() indexOfObject:a.category];
        NSUInteger ib = [DLCategoryOrder() indexOfObject:b.category];
        if (ia != ib) return ia < ib ? NSOrderedAscending : NSOrderedDescending;
        return [a.name localizedCaseInsensitiveCompare:b.name];
    }];
    return result;
}

#pragma mark - helpers

+ (BOOL)isDirSortQuery:(NSString *)query {
    if (query.length == 0) return NO;
    for (NSString *part in [query componentsSeparatedByString:@"&"]) {
        NSString *u = part.uppercaseString;
        if (!([u hasPrefix:@"C="] || [u hasPrefix:@"O="])) return NO;
    }
    return YES;
}

+ (BOOL)isSkipAssetExtension:(NSString *)ext {
    if (ext.length == 0) return NO;
    static NSSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSSet setWithArray:@[@"css", @"js", @"mjs", @"map", @"woff", @"woff2",
                                    @"ttf", @"otf", @"eot", @"ico"]];
    });
    return [set containsObject:ext];
}

+ (NSString *)normalizedHost:(NSString *)host {
    if (!host) return @"";
    NSString *h = host.lowercaseString;
    if ([h hasPrefix:@"www."]) h = [h substringFromIndex:4];
    return h;
}

+ (NSURL *)baseURLFromHTML:(NSString *)html fallback:(NSURL *)fallback {
    NSRegularExpression *re = [NSRegularExpression
        regularExpressionWithPattern:@"(?i)<base\\s+[^>]*href\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')"
                             options:0 error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:html options:0 range:NSMakeRange(0, html.length)];
    if (m) {
        NSString *href = nil;
        if ([m rangeAtIndex:1].location != NSNotFound) href = [html substringWithRange:[m rangeAtIndex:1]];
        else if ([m rangeAtIndex:2].location != NSNotFound) href = [html substringWithRange:[m rangeAtIndex:2]];
        if (href.length) {
            NSURL *u = [NSURL URLWithString:href relativeToURL:fallback];
            if (u) return u;
        }
    }
    return fallback;
}

+ (NSString *)displayNameForURL:(NSURL *)url {
    NSString *last = url.lastPathComponent;
    last = [last stringByRemovingPercentEncoding] ?: last;
    if (last.length == 0) {
        last = url.host ?: url.absoluteString;
    }
    return last;
}

+ (NSString *)decodeHTMLEntities:(NSString *)text {
    if ([text rangeOfString:@"&"].location == NSNotFound) return text;
    NSMutableString *s = [text mutableCopy];
    NSDictionary *map = @{@"&amp;": @"&", @"&quot;": @"\"", @"&#39;": @"'", @"&apos;": @"'",
                          @"&lt;": @"<", @"&gt;": @">", @"&nbsp;": @" "};
    for (NSString *k in map) {
        [s replaceOccurrencesOfString:k withString:map[k] options:NSCaseInsensitiveSearch
                              range:NSMakeRange(0, s.length)];
    }
    /* 数字实体 &#123; */
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"&#(x?[0-9a-fA-F]+);" options:0 error:nil];
    NSArray<NSTextCheckingResult *> *ms = [re matchesInString:s options:0 range:NSMakeRange(0, s.length)];
    for (NSTextCheckingResult *m in [ms reverseObjectEnumerator]) {
        NSString *num = [s substringWithRange:[m rangeAtIndex:1]];
        unsigned int code = 0;
        if ([num.lowercaseString hasPrefix:@"x"]) {
            sscanf(num.UTF8String + 1, "%x", &code);
        } else {
            sscanf(num.UTF8String, "%u", &code);
        }
        if (code > 0 && code < 0x110000) {
            NSString *ch = [NSString stringWithFormat:@"%C", (unichar)code];
            if (code > 0xFFFF) {
                /* 补充平面：转 UTF-16 代理对 */
                code -= 0x10000;
                unichar hi = 0xD800 + (code >> 10);
                unichar lo = 0xDC00 + (code & 0x3FF);
                ch = [NSString stringWithCharacters:(unichar[]){hi, lo} length:2];
            }
            [s replaceCharactersInRange:m.range withString:ch];
        }
    }
    return s;
}

@end
