#import "AppDelegate.h"
#import "DLListViewController.h"
#import "DLCrawlViewController.h"
#import "DLSettingsViewController.h"
#if DLBOX_WITH_BT
#import "DLBTViewController.h"
#endif
#if DLBOX_WITH_LT
#import "DLBTTorrentsViewController.h"
#endif
#import "DLDownloadEngine.h"
#import "DLLog.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [DLLog setup];
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.window.tintColor = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0];

    // 全局深色外观（最低 iOS 14，scrollEdgeAppearance 为 iOS 15+ 用 respondsToSelector 保护）
    UINavigationBarAppearance *navApp = [[UINavigationBarAppearance alloc] init];
    [navApp configureWithOpaqueBackground];
    navApp.backgroundColor = [UIColor colorWithWhite:0.09 alpha:1.0];
    navApp.titleTextAttributes = @{NSForegroundColorAttributeName: [UIColor whiteColor]};
    [[UINavigationBar appearance] setStandardAppearance:navApp];
    UITabBarAppearance *tabApp = [[UITabBarAppearance alloc] init];
    [tabApp configureWithOpaqueBackground];
    tabApp.backgroundColor = [UIColor colorWithWhite:0.09 alpha:1.0];
    [[UITabBar appearance] setStandardAppearance:tabApp];

    // scrollEdgeAppearance 为 iOS 15+，用 respondsToSelector 保护
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
    if ([[UINavigationBar appearance] respondsToSelector:@selector(setScrollEdgeAppearance:)]) {
        [[UINavigationBar appearance] setScrollEdgeAppearance:navApp];
    }
    if ([[UITabBar appearance] respondsToSelector:@selector(setScrollEdgeAppearance:)]) {
        [[UITabBar appearance] setScrollEdgeAppearance:tabApp];
    }
#pragma clang diagnostic pop

    DLListViewController *list = [[DLListViewController alloc] init];
    UINavigationController *nav1 = [[UINavigationController alloc] initWithRootViewController:list];
    nav1.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"下载"
                                                    image:[UIImage systemImageNamed:@"arrow.down.circle"]
                                                      tag:0];

    DLSettingsViewController *settings = [[DLSettingsViewController alloc] init];
    UINavigationController *nav2 = [[UINavigationController alloc] initWithRootViewController:settings];
    nav2.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"设置"
                                                    image:[UIImage systemImageNamed:@"gearshape"]
                                                      tag:2];

    DLCrawlViewController *crawl = [[DLCrawlViewController alloc] init];
    UINavigationController *navCrawl = [[UINavigationController alloc] initWithRootViewController:crawl];
    UIImage *crawlIcon = [UIImage systemImageNamed:@"text.magnifyingglass"];
    if (!crawlIcon) crawlIcon = [UIImage systemImageNamed:@"magnifyingglass"];
    navCrawl.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"抓取" image:crawlIcon tag:1];

#if DLBOX_WITH_LT
    DLBTTorrentsViewController *btvc = [[DLBTTorrentsViewController alloc] init];
    UINavigationController *navBT = [[UINavigationController alloc] initWithRootViewController:btvc];
    navBT.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"BT"
                                                    image:[UIImage systemImageNamed:@"arrow.triangle.2.circlepath"]
                                                      tag:3];
#elif DLBOX_WITH_BT
    DLBTViewController *bt = [[DLBTViewController alloc] init];
    UINavigationController *nav3 = [[UINavigationController alloc] initWithRootViewController:bt];
    nav3.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"BT"
                                                    image:[UIImage systemImageNamed:@"arrow.triangle.2.circlepath"]
                                                      tag:3];
#endif

    UITabBarController *tab = [[UITabBarController alloc] init];
#if DLBOX_WITH_LT
    /* libtorrent 2.0.11 内核（iTorrent 移植） */
    tab.viewControllers = @[nav1, navCrawl, nav2, navBT];
#elif DLBOX_WITH_BT
    tab.viewControllers = @[nav1, navCrawl, nav2, nav3];
#else
    /* BT 引擎已随 P4 烂尾冻结：WITH_BT=0 时不挂 BT 页，源码仍保留在 src/ 里 */
    tab.viewControllers = @[nav1, navCrawl, nav2];
#endif

    self.window.rootViewController = tab;
    [self.window makeKeyAndVisible];

    [[DLDownloadEngine sharedEngine] start];
    return YES;
}

- (void)application:(UIApplication *)application
    handleEventsForBackgroundURLSession:(NSString *)identifier
                      completionHandler:(void (^)(void))completionHandler {
    [[DLDownloadEngine sharedEngine] handleEventsForBackgroundURLSession:identifier
                                                      completionHandler:completionHandler];
}

- (void)applicationDidReceiveMemoryWarning:(UIApplication *)application {
    /* 内存警告往往出现在被系统杀掉之前，记一笔方便对照心跳曲线 */
    [DLLog write:[NSString stringWithFormat:@"⚠️ 收到内存警告 · 内存 %@", [DLLog memoryString]]];
}

- (void)applicationWillTerminate:(UIApplication *)application {
    [DLLog markCleanExit];
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    [DLLog write:[NSString stringWithFormat:@"应用进入后台 · 内存 %@", [DLLog memoryString]]];
}

@end
