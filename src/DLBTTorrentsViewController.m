#import "DLBTTorrentsViewController.h"
#import "DLBTLib.h"
#import "DLLog.h"

static NSString *const kBTHeaderFont = nil;

static NSString *FormatBytes(long long bytes) {
    if (bytes < 1024) return [NSString stringWithFormat:@"%lld B", bytes];
    if (bytes < 1024 * 1024) return [NSString stringWithFormat:@"%.1f KB", bytes / 1024.0];
    if (bytes < 1024LL * 1024 * 1024) return [NSString stringWithFormat:@"%.1f MB", bytes / (1024.0 * 1024.0)];
    return [NSString stringWithFormat:@"%.2f GB", bytes / (1024.0 * 1024.0 * 1024.0)];
}

static NSString *FormatSpeed(double bps) {
    if (bps < 1024) return [NSString stringWithFormat:@"%.0f B/s", bps];
    if (bps < 1024 * 1024) return [NSString stringWithFormat:@"%.1f KB/s", bps / 1024.0];
    return [NSString stringWithFormat:@"%.2f MB/s", bps / (1024.0 * 1024.0)];
}

#pragma mark - Cell

@interface DLBTCell : UITableViewCell
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIProgressView *progressBar;
@property (nonatomic, strong) UIButton *actionButton;
@property (nonatomic, copy) void (^onAction)(void);
- (void)configureWithTask:(DLBTTask *)task;
@end

@implementation DLBTCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:0.055 alpha:1.0];
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        _nameLabel = [[UILabel alloc] init];
        _nameLabel.textColor = [UIColor whiteColor];
        _nameLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        _nameLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [self.contentView addSubview:_nameLabel];

        _statusLabel = [[UILabel alloc] init];
        _statusLabel.textColor = [UIColor colorWithWhite:0.62 alpha:1.0];
        _statusLabel.font = [UIFont systemFontOfSize:11];
        [self.contentView addSubview:_statusLabel];

        _progressBar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
        _progressBar.progressTintColor = [UIColor colorWithRed:0.0 green:0.52 blue:1.0 alpha:1.0];
        _progressBar.trackTintColor = [UIColor colorWithWhite:0.2 alpha:1.0];
        [self.contentView addSubview:_progressBar];

        _actionButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _actionButton.titleLabel.font = [UIFont systemFontOfSize:22];
        [_actionButton addTarget:self action:@selector(actionTapped) forControlEvents:UIControlEventTouchUpInside];
        [self.contentView addSubview:_actionButton];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.contentView.bounds.size.width;
    CGFloat h = self.contentView.bounds.size.height;
    _actionButton.frame = CGRectMake(w - 52, (h - 40) / 2.0, 44, 40);
    _nameLabel.frame = CGRectMake(16, 10, w - 76, 20);
    _statusLabel.frame = CGRectMake(16, 32, w - 76, 14);
    _progressBar.frame = CGRectMake(16, h - 16, w - 76, 3);
}

- (void)actionTapped {
    if (self.onAction) self.onAction();
}

- (void)configureWithTask:(DLBTTask *)task {
    self.nameLabel.text = task.name.length ? task.name : task.infoHash;
    NSString *icon = @"⏸";
    switch (task.state) {
        case DLBTTaskStatePaused:   icon = @"▶️"; break;
        case DLBTTaskStateError:    icon = @"⚠️"; break;
        case DLBTTaskStateSeeding:  icon = @"⏸"; break;
        default:                    icon = @"⏸"; break;
    }
    [self.actionButton setTitle:icon forState:UIControlStateNormal];

    NSString *detail;
    if (task.state == DLBTTaskStateMetadata) {
        detail = [NSString stringWithFormat:@"%@ · 连接 %ld · ↓ %@", task.stateText,
                  (long)task.numPeers, FormatSpeed(task.downloadRate)];
    } else if (task.state == DLBTTaskStateError) {
        detail = task.errorText.length ? task.errorText : @"错误";
    } else {
        detail = [NSString stringWithFormat:@"%@ · %.1f%% · ↓%@ ↑%@ · %ld peer",
                  task.stateText, task.progress * 100.0,
                  FormatSpeed(task.downloadRate), FormatSpeed(task.uploadRate),
                  (long)task.numPeers];
        if (task.totalWanted > 0) {
            detail = [detail stringByAppendingFormat:@" · %@/%@",
                      FormatBytes(task.totalDone), FormatBytes(task.totalWanted)];
        }
    }
    self.statusLabel.text = detail;
    self.progressBar.progress = (float)task.progress;

    if (task.state == DLBTTaskStateSeeding || task.state == DLBTTaskStateFinished) {
        self.progressBar.progressTintColor = [UIColor colorWithRed:0.2 green:0.78 blue:0.45 alpha:1.0];
    } else if (task.state == DLBTTaskStateError) {
        self.progressBar.progressTintColor = [UIColor colorWithRed:0.95 green:0.35 blue:0.3 alpha:1.0];
    } else {
        self.progressBar.progressTintColor = [UIColor colorWithRed:0.0 green:0.52 blue:1.0 alpha:1.0];
    }
}

@end

#pragma mark - VC

@interface DLBTTorrentsViewController () <UITableViewDataSource, UITableViewDelegate>
@end

@implementation DLBTTorrentsViewController {
    UITableView *_tableView;
    NSArray<DLBTTask *> *_tasks;
    UILabel *_emptyLabel;
    NSTimer *_timer;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"BT 下载";
    self.view.backgroundColor = [UIColor colorWithWhite:0.055 alpha:1.0];

    UIBarButtonItem *add = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                                         target:self action:@selector(addTapped)];
    self.navigationItem.rightBarButtonItem = add;
    UIBarButtonItem *limit = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"dial.medium"]
                                                              style:UIBarButtonItemStylePlain
                                                             target:self action:@selector(limitTapped)];
    self.navigationItem.leftBarButtonItem = limit;

    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.backgroundColor = [UIColor colorWithWhite:0.055 alpha:1.0];
    _tableView.separatorColor = [UIColor colorWithWhite:0.16 alpha:1.0];
    _tableView.separatorInset = UIEdgeInsetsMake(0, 16, 0, 0);
    _tableView.rowHeight = 78;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    [_tableView registerClass:[DLBTCell class] forCellReuseIdentifier:@"DLBTCell"];
    [self.view addSubview:_tableView];

    _emptyLabel = [[UILabel alloc] init];
    _emptyLabel.text = @"暂无 BT 任务\n点右上角 + 添加磁力链接或种子文件";
    _emptyLabel.numberOfLines = 0;
    _emptyLabel.textAlignment = NSTextAlignmentCenter;
    _emptyLabel.font = [UIFont systemFontOfSize:14];
    _emptyLabel.textColor = [UIColor colorWithWhite:0.45 alpha:1.0];
    _emptyLabel.frame = CGRectMake(0, 0, self.view.bounds.size.width, 60);
    [self.view addSubview:_emptyLabel];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reload)
                                                 name:DLBTTasksChangedNotification object:nil];

    [[DLBTLib shared] start];
    [self reload];

    _timer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(reload) userInfo:nil repeats:YES];
    _timer.tolerance = 0.3;
}

- (void)dealloc {
    [_timer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _emptyLabel.center = CGPointMake(self.view.bounds.size.width / 2.0,
                                     self.view.bounds.size.height / 2.0 - 20);
}

- (void)reload {
    _tasks = [[DLBTLib shared] tasks];
    [_tableView reloadData];
    _emptyLabel.hidden = _tasks.count > 0;
    UIBarButtonItem *limit = self.navigationItem.leftBarButtonItem;
    limit.enabled = _tasks.count > 0;
}

#pragma mark - Actions

- (void)addTapped {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:nil message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    NSString *clip = [UIPasteboard generalPasteboard].string;
    if ([clip hasPrefix:@"magnet:"]) {
        NSString *clipShort = clip.length > 48 ? [[clip substringToIndex:48] stringByAppendingString:@"…"] : clip;
        [sheet addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"粘贴：%@", clipShort]
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) { [self addMagnet:clip]; }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"输入磁力链接" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) { [self promptMagnet]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"导入 .torrent 文件" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) { [self pickTorrentFile]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)promptMagnet {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"添加磁力链接"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"magnet:?xt=urn:btih:…";
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"添加" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self addMagnet:alert.textFields.firstObject.text];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)addMagnet:(NSString *)uri {
    if (![uri hasPrefix:@"magnet:"]) {
        [self toast:@"不是有效的磁力链接"];
        return;
    }
    NSString *err = nil;
    if ([[DLBTLib shared] addMagnet:uri error:&err]) {
        [self toast:@"已添加，正在获取元数据…"];
        [self reload];
    } else {
        [self toast:[NSString stringWithFormat:@"添加失败：%@", err ?: @"未知错误"]];
    }
}

- (void)pickTorrentFile {
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"org.bittorrent.torrent", @"public.data"]
                                                               inMode:UIDocumentPickerModeImport];
    picker.delegate = (id)self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;
    NSString *err = nil;
    if ([[DLBTLib shared] addTorrentFile:url.path error:&err]) {
        [self toast:@"种子已添加"];
        [self reload];
    } else {
        [self toast:[NSString stringWithFormat:@"添加失败：%@", err ?: @"未知错误"]];
    }
}

- (void)limitTapped {
    NSInteger down = [[NSUserDefaults standardUserDefaults] integerForKey:@"dlbox.bt.downLimit"];
    NSInteger up = [[NSUserDefaults standardUserDefaults] integerForKey:@"dlbox.bt.upLimit"];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"全局限速"
                                                                   message:@"单位 KB/s，填 0 表示不限速"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"下载 KB/s";
        tf.keyboardType = UIKeyboardTypeNumberPad;
        if (down > 0) tf.text = [NSString stringWithFormat:@"%ld", (long)down];
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"上传 KB/s";
        tf.keyboardType = UIKeyboardTypeNumberPad;
        if (up > 0) tf.text = [NSString stringWithFormat:@"%ld", (long)up];
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"应用" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSInteger d = [alert.textFields[0].text integerValue];
        NSInteger u = [alert.textFields[1].text integerValue];
        [[DLBTLib shared] setDownloadLimitKB:d uploadLimitKB:u];
        [self toast:d == 0 && u == 0 ? @"已取消限速" : [NSString stringWithFormat:@"限速 ↓%ld ↑%ld KB/s", (long)d, (long)u]];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)toast:(NSString *)text {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:nil message:text
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:a animated:YES completion:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [a dismissViewControllerAnimated:YES completion:nil];
        });
    }];
}

#pragma mark - UITableView

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _tasks.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    DLBTCell *cell = [tableView dequeueReusableCellWithIdentifier:@"DLBTCell" forIndexPath:indexPath];
    DLBTTask *t = _tasks[indexPath.row];
    [cell configureWithTask:t];
    __weak typeof(self) weakSelf = self;
    cell.onAction = ^{
        if (t.state == DLBTTaskStatePaused) {
            [[DLBTLib shared] resumeTask:t.infoHash];
        } else {
            [[DLBTLib shared] pauseTask:t.infoHash];
        }
        [weakSelf reload];
    };
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    DLBTTask *t = _tasks[indexPath.row];
    NSString *msg = [NSString stringWithFormat:@"%@\n%@\n%@ / %@\npeer %ld · seed %ld\n%@",
                     t.name, t.infoHash, FormatBytes(t.totalDone), FormatBytes(t.totalWanted),
                     (long)t.numPeers, (long)t.numSeeds,
                     [DLBTLib shared].versionString];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"任务详情" message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    DLBTTask *t = _tasks[indexPath.row];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"删除任务"
                                                               message:@"是否同时删除已下载的文件？"
                                                        preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:@"只删任务" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
        [[DLBTLib shared] removeTask:t.infoHash deleteFiles:NO];
        [self reload];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"任务和文件一起删" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
        [[DLBTLib shared] removeTask:t.infoHash deleteFiles:YES];
        [self reload];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = tableView;
    a.popoverPresentationController.sourceRect = [tableView rectForRowAtIndexPath:indexPath];
    [self presentViewController:a animated:YES completion:nil];
}

@end
