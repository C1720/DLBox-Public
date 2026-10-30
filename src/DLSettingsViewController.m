#import "DLSettingsViewController.h"
#import "DLSettings.h"
#import "DLDownloadEngine.h"
#import "DLTask.h"
#import "DLFilesViewController.h"
#if DLBOX_WITH_BT
#import "DLBTSession.h"
#endif
#import "DLLog.h"

@interface DLSettingsViewController () <UITableViewDataSource, UITableViewDelegate>
@end

@implementation DLSettingsViewController {
    UITableView *_tableView;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"设置";
    self.view.backgroundColor = [UIColor colorWithWhite:0.055 alpha:1.0];

    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleGrouped];
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.backgroundColor = [UIColor colorWithWhite:0.055 alpha:1.0];
    _tableView.dataSource = self;
    _tableView.delegate = self;
    [self.view addSubview:_tableView];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [_tableView reloadData];
}

#pragma mark - Helpers

- (NSString *)rateText {
    NSInteger k = [DLSettings shared].rateLimitKBs;
    if (k <= 0) return @"不限";
    if (k < 1024) return [NSString stringWithFormat:@"%ld KB/s", (long)k];
    return [NSString stringWithFormat:@"%ld MB/s", (long)(k / 1024)];
}

- (void)chooseTitle:(NSString *)title options:(NSArray<NSString *> *)opts currentIndex:(NSInteger)cur handler:(void (^)(NSInteger))handler {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [opts enumerateObjectsUsingBlock:^(NSString *name, NSUInteger idx, BOOL *stop) {
        NSString *label = (idx == cur) ? [NSString stringWithFormat:@"✓ %@", name] : name;
        UIAlertAction *act = [UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            handler(idx);
        }];
        [alert addAction:act];
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 5;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0: return 4; // 并发 / 分段 / 限速 / 模式
        case 1: return 1; // 允许 HTTP
        case 2: return 2; // 下载目录 / 清空已完成
        case 3: return DLBOX_WITH_BT ? 2 : 1; // BT 日志（仅 WITH_BT=1）/ 诊断日志
        case 4: return 2; // 后台说明 / 版本
    }
    return 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return @"下载";
        case 1: return @"网络";
        case 2: return @"存储";
        case 3: return DLBOX_WITH_BT ? @"BT" : @"日志";
        case 4: return @"关于";
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"cell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:cid];
        cell.backgroundColor = [UIColor colorWithWhite:0.09 alpha:1.0];
        cell.textLabel.textColor = [UIColor whiteColor];
        cell.detailTextLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
        cell.textLabel.font = [UIFont systemFontOfSize:15];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:14];
    }
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.textLabel.text = @"";
    cell.detailTextLabel.text = @"";

    DLSettings *s = [DLSettings shared];
    NSInteger sec = indexPath.section, row = indexPath.row;

    if (sec == 0) {
        if (row == 0) {
            cell.textLabel.text = @"并发下载数";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld", (long)s.maxConcurrent];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (row == 1) {
            cell.textLabel.text = @"分段数（多段加速）";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld 段", (long)s.segmentCount];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (row == 2) {
            cell.textLabel.text = @"限速";
            cell.detailTextLabel.text = [self rateText];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            cell.textLabel.text = @"下载模式";
            cell.detailTextLabel.text = s.downloadMode == 1 ? @"后台整段" : @"分段加速";
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    } else if (sec == 1) {
        cell.textLabel.text = @"允许 HTTP 明文下载";
        cell.detailTextLabel.text = s.allowHTTP ? @"开" : @"关";
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = s.allowHTTP;
        [sw addTarget:self action:@selector(httpChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (sec == 2) {
        if (row == 0) {
            cell.textLabel.text = @"下载目录";
            cell.detailTextLabel.text = @"查看 / 分享 / 删除文件";
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            cell.textLabel.text = @"清空已完成";
            cell.detailTextLabel.text = @"移除已完成 / 失败的任务记录";
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    } else if (sec == 3) {
        NSInteger diagRow = DLBOX_WITH_BT ? 1 : 0;
        if (row == diagRow) {
            cell.textLabel.text = @"诊断日志";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"落盘 · 内存 %@", [DLLog memoryString]];
        } else {
            cell.textLabel.text = @"导出 BT 日志";
            cell.detailTextLabel.text = @"复制 / 分享下载日志";
        }
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        if (row == 0) {
            cell.textLabel.text = @"后台下载行为说明";
            cell.detailTextLabel.text = @"查看";
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            cell.textLabel.text = @"版本";
            NSString *ver = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
            cell.detailTextLabel.text = ver ?: @"0.1.0";
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
    }
    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    if ([view isKindOfClass:[UITableViewHeaderFooterView class]]) {
        UITableViewHeaderFooterView *hv = (UITableViewHeaderFooterView *)view;
        hv.contentView.backgroundColor = [UIColor colorWithWhite:0.055 alpha:1.0];
        hv.textLabel.textColor = [UIColor colorWithWhite:0.55 alpha:1.0];
        hv.textLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    DLSettings *s = [DLSettings shared];
    NSInteger sec = indexPath.section, row = indexPath.row;

    if (sec == 0 && row == 0) {
        [self chooseTitle:@"并发下载数" options:@[@"1", @"2", @"3", @"4", @"6"] currentIndex:[@[@1,@2,@3,@4,@6] indexOfObject:@(s.maxConcurrent)] == NSNotFound ? 1 : [@[@1,@2,@3,@4,@6] indexOfObject:@(s.maxConcurrent)]
                 handler:^(NSInteger idx) {
            NSArray *vals = @[@1,@2,@3,@4,@6];
            [DLSettings shared].maxConcurrent = [vals[idx] integerValue];
            [[DLDownloadEngine sharedEngine] applySettings];
            [self->_tableView reloadData];
        }];
    } else if (sec == 0 && row == 1) {
        NSArray *vals = @[@1,@2,@3,@4,@6,@8];
        NSInteger cur = [vals indexOfObject:@(s.segmentCount)];
        if (cur == NSNotFound) cur = 3;
        [self chooseTitle:@"分段数" options:@[@"1 段", @"2 段", @"3 段", @"4 段", @"6 段", @"8 段"] currentIndex:cur
                 handler:^(NSInteger idx) {
            [DLSettings shared].segmentCount = [vals[idx] integerValue];
            [self->_tableView reloadData];
        }];
    } else if (sec == 0 && row == 2) {
        NSArray *vals = @[@0,@256,@512,@1024,@2048,@5120];
        NSInteger cur = [vals indexOfObject:@(s.rateLimitKBs)];
        if (cur == NSNotFound) cur = 0;
        [self chooseTitle:@"限速" options:@[@"不限", @"256 KB/s", @"512 KB/s", @"1 MB/s", @"2 MB/s", @"5 MB/s"] currentIndex:cur
                 handler:^(NSInteger idx) {
            [DLSettings shared].rateLimitKBs = [vals[idx] integerValue];
            [[DLDownloadEngine sharedEngine] applySettings];
            [self->_tableView reloadData];
        }];
    } else if (sec == 0 && row == 3) {
        [self chooseTitle:@"下载模式" options:@[@"分段加速（多段并发，更快）", @"后台整段（切后台/锁屏不中断）"] currentIndex:s.downloadMode
                 handler:^(NSInteger idx) {
            [DLSettings shared].downloadMode = idx;
            [self->_tableView reloadData];
        }];
    } else if (sec == 2 && row == 0) {
        DLFilesViewController *vc = [[DLFilesViewController alloc] init];
        [self.navigationController pushViewController:vc animated:YES];
    } else if (sec == 2 && row == 1) {
        [self confirmClearFinished];
    } else if (sec == 3) {
        NSInteger diagRow = DLBOX_WITH_BT ? 1 : 0;
        if (row == diagRow) {
            [self exportDiagLog];
        } else if (DLBOX_WITH_BT) {
            [self exportBTLog];
        }
    } else if (sec == 4 && row == 0) {
        [self showBackgroundInfo];
    }
}

- (void)httpChanged:(UISwitch *)sw {
    [DLSettings shared].allowHTTP = sw.on;
}

- (void)confirmClearFinished {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"清空已完成"
                                                                   message:@"将移除任务列表中「已完成 / 失败」的记录（已下载的文件保留）。"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"清空" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        for (DLTask *t in [[DLDownloadEngine sharedEngine] allTasks]) {
            if (t.state == DLTaskStateCompleted || t.state == DLTaskStateFailed) {
                [[DLDownloadEngine sharedEngine] removeTask:t.taskId];
            }
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showBackgroundInfo {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"下载模式说明"
                                                                   message:@"后台整段：走 iOS 后台会话，切后台 / 锁屏后系统继续下载，App 被上滑杀掉后也能断点续下。\n\n分段加速：把文件拆成多段并发下载，速度更快；但依赖前台，App 被系统挂起后会暂停，回到前台自动续传（已下载的分段进度会保留）。"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)exportBTLog {
#if DLBOX_WITH_BT
    NSString *log = [DLBTSession shared].logText;
#else
    NSString *log = @"";   /* BT 引擎已冻结，本入口在 WITH_BT=0 时不会出现 */
#endif
    if (log.length == 0) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"暂无日志"
            message:@"还没有 BT 下载日志。先去「BT」页跑一个任务，再回来导出。"
            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [docs stringByAppendingPathComponent:@"dlbox"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [dir stringByAppendingPathComponent:@"bt-log.txt"];
    [log writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];

    /* 同时复制到剪贴板，方便直接粘贴 */
    [UIPasteboard generalPasteboard].string = log;

    UIActivityViewController *avc = [[UIActivityViewController alloc]
        initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
    avc.popoverPresentationController.sourceView = self.view;
    avc.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2.0,
                                                               self.view.bounds.size.height / 2.0, 1, 1);
    [self presentViewController:avc animated:YES completion:nil];
}

- (void)exportDiagLog {
    /* 诊断日志：落盘的引擎日志 + 崩溃记录 + 内存心跳，闪退后重新打开 App 也能导出 */
    NSString *content = [DLLog content];
    if (content.length == 0) content = @"（日志为空）";
    [DLLog write:[NSString stringWithFormat:@"[导出] 用户导出诊断日志 · 内存 %@", [DLLog memoryString]]];

    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [docs stringByAppendingPathComponent:@"dlbox"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [dir stringByAppendingPathComponent:@"dlbox-diag.log"];
    [content writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [UIPasteboard generalPasteboard].string = content;

    UIActivityViewController *avc = [[UIActivityViewController alloc]
        initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
    avc.popoverPresentationController.sourceView = self.view;
    avc.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2.0,
                                                               self.view.bounds.size.height / 2.0, 1, 1);
    [self presentViewController:avc animated:YES completion:nil];
}

@end
