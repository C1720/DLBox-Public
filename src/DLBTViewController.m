#import "DLBTViewController.h"
#import "DLBTSession.h"

static NSString *fmtSize(uint64_t n) {
    if (n >= 1024 * 1024 * 1024) return [NSString stringWithFormat:@"%.2f GB", n / (1024.0 * 1024.0 * 1024.0)];
    if (n >= 1024 * 1024) return [NSString stringWithFormat:@"%.2f MB", n / (1024.0 * 1024.0)];
    if (n >= 1024) return [NSString stringWithFormat:@"%.1f KB", n / 1024.0];
    return [NSString stringWithFormat:@"%llu B", (unsigned long long)n];
}

static NSString *fmtSpeed(int64_t s) {
    if (s >= 1024 * 1024) return [NSString stringWithFormat:@"%.2f MB/s", s / (1024.0 * 1024.0)];
    if (s >= 1024) return [NSString stringWithFormat:@"%.1f KB/s", s / 1024.0];
    return [NSString stringWithFormat:@"%lld B/s", (long long)s];
}

static NSString *fmtETA(uint64_t remaining, int64_t speed) {
    if (speed <= 0 || remaining == 0) return @"--";
    double sec = (double)remaining / (double)speed;
    if (sec < 60) return [NSString stringWithFormat:@"%.0f 秒", sec];
    if (sec < 3600) return [NSString stringWithFormat:@"%.0f 分", sec / 60.0];
    if (sec < 86400) {
        int h = (int)(sec / 3600.0);
        int m = (int)((sec - h * 3600.0) / 60.0);
        return [NSString stringWithFormat:@"%d 时 %d 分", h, m];
    }
    return [NSString stringWithFormat:@"%.1f 天", sec / 86400.0];
}

@interface DLBTViewController () <UITextFieldDelegate>
@end

@implementation DLBTViewController {
    UITextField *_input;
    UILabel *_statusLabel;
    UIProgressView *_progress;
    UILabel *_detailLabel;
    UITextView *_logView;
    UIButton *_pasteBtn;
    UIButton *_pickBtn;
    UIButton *_startBtn;
    UIButton *_stopBtn;
    BOOL _logRefreshPending;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"BT 下载 · P4-fix13";
    self.view.backgroundColor = [UIColor colorWithWhite:0.055 alpha:1.0];

    _input = [[UITextField alloc] init];
    _input.placeholder = @"粘贴 .torrent / magnet 链接 或 本地路径";
    _input.backgroundColor = [UIColor colorWithWhite:0.11 alpha:1.0];
    _input.textColor = [UIColor whiteColor];
    _input.font = [UIFont systemFontOfSize:14];
    _input.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 44)];
    _input.leftViewMode = UITextFieldViewModeAlways;
    _input.layer.cornerRadius = 10;
    _input.keyboardAppearance = UIKeyboardAppearanceDark;
    _input.autocorrectionType = UITextAutocorrectionTypeNo;
    _input.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _input.returnKeyType = UIReturnKeyDone;
    _input.delegate = self;
    [self.view addSubview:_input];

    _pasteBtn = [self makeButton:@"粘贴" color:[UIColor colorWithWhite:0.20 alpha:1.0]];
    _pickBtn  = [self makeButton:@"选种子" color:[UIColor colorWithWhite:0.20 alpha:1.0]];
    _startBtn = [self makeButton:@"开始下载" color:[UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0]];
    _stopBtn  = [self makeButton:@"停止" color:[UIColor colorWithRed:0.85 green:0.25 blue:0.25 alpha:1.0]];
    [_pasteBtn addTarget:self action:@selector(pasteTapped) forControlEvents:UIControlEventTouchUpInside];
    [_pickBtn addTarget:self action:@selector(pickTorrent) forControlEvents:UIControlEventTouchUpInside];
    [_startBtn addTarget:self action:@selector(startDownload) forControlEvents:UIControlEventTouchUpInside];
    [_stopBtn addTarget:self action:@selector(stopTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_pasteBtn];
    [self.view addSubview:_pickBtn];
    [self.view addSubview:_startBtn];
    [self.view addSubview:_stopBtn];

    _statusLabel = [[UILabel alloc] init];
    _statusLabel.textColor = [UIColor whiteColor];
    _statusLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [self.view addSubview:_statusLabel];

    _progress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    _progress.progressTintColor = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0];
    _progress.trackTintColor = [UIColor colorWithWhite:0.16 alpha:1.0];
    [self.view addSubview:_progress];

    _detailLabel = [[UILabel alloc] init];
    _detailLabel.textColor = [UIColor colorWithWhite:0.62 alpha:1.0];
    _detailLabel.font = [UIFont systemFontOfSize:12];
    _detailLabel.numberOfLines = 1;
    [self.view addSubview:_detailLabel];

    _logView = [[UITextView alloc] init];
    _logView.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1.0];
    _logView.textColor = [UIColor colorWithWhite:0.85 alpha:1.0];
    _logView.font = [UIFont fontWithName:@"Menlo" size:12] ?: [UIFont systemFontOfSize:12];
    _logView.editable = NO;
    _logView.layer.cornerRadius = 10;
    _logView.textContainerInset = UIEdgeInsetsMake(10, 8, 10, 8);
    [self.view addSubview:_logView];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onLog:)
                                                 name:DLBTSessionLogNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onProgress:)
                                                 name:DLBTSessionProgressNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onState:)
                                                 name:DLBTSessionStateNotification object:nil];

    [self refreshAll];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (UIButton *)makeButton:(NSString *)title color:(UIColor *)color {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    b.layer.cornerRadius = 10;
    b.backgroundColor = color;
    return b;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIEdgeInsets insets = self.view.safeAreaInsets;
    CGFloat w = self.view.bounds.size.width;
    CGFloat h = self.view.bounds.size.height;
    CGFloat pad = 14;
    CGFloat gap = 10;
    CGFloat y = insets.top + 8;

    _input.frame = CGRectMake(pad, y, w - pad * 2, 44);
    y += 44 + gap;

    CGFloat btnGap = 8;
    CGFloat bw = (w - pad * 2 - btnGap * 3) / 4.0;
    _pasteBtn.frame = CGRectMake(pad, y, bw, 42);
    _pickBtn.frame  = CGRectMake(pad + (bw + btnGap), y, bw, 42);
    _startBtn.frame = CGRectMake(pad + (bw + btnGap) * 2, y, bw, 42);
    _stopBtn.frame  = CGRectMake(pad + (bw + btnGap) * 3, y, bw, 42);
    y += 42 + 14;

    _statusLabel.frame = CGRectMake(pad + 2, y, w - pad * 2, 22);
    y += 22 + 6;

    _progress.frame = CGRectMake(pad + 2, y, w - (pad + 2) * 2, 4);
    y += 4 + 8;

    _detailLabel.frame = CGRectMake(pad + 2, y, w - pad * 2, 18);
    y += 18 + 10;

    CGFloat bottom = h - insets.bottom - 10;
    _logView.frame = CGRectMake(pad, y, w - pad * 2, bottom - y);
}

#pragma mark - 刷新

- (void)refreshAll {
    DLBTSession *s = [DLBTSession shared];
    [self updateProgressLabels];
    _logView.text = s.logText;
    [self scrollLog];
    BOOL running = (s.state == DLBTSessionStateRunning);
    _startBtn.enabled = !running;
    _stopBtn.enabled = running;
    _startBtn.alpha = running ? 0.4 : 1.0;
    _stopBtn.alpha = running ? 1.0 : 0.4;
}

- (void)updateProgressLabels {
    DLBTSession *s = [DLBTSession shared];
    double p = s.totalBytes > 0 ? (double)s.doneBytes / (double)s.totalBytes : 0;
    _progress.progress = (float)p;
    NSString *name = s.name.length ? s.name : @"";

    if (s.state == DLBTSessionStateRunning) {
        if (s.totalBytes == 0) {
            _statusLabel.text = @"获取元数据中…";
            _detailLabel.text = [NSString stringWithFormat:@"%@  ·  peer %ld", name, (long)s.peerCount];
        } else if (s.seeding) {
            _statusLabel.text = [NSString stringWithFormat:@"做种中 · 100.00%% · %@", fmtSpeed(s.speed)];
            _detailLabel.text = [NSString stringWithFormat:@"%@  已完整 %@  ·  peer %ld",
                                 name, fmtSize(s.doneBytes), (long)s.peerCount];
        } else {
            double pct = s.totalBytes > 0 ? (double)s.doneBytes / (double)s.totalBytes * 100.0 : 0;
            uint64_t remain = s.totalBytes > s.doneBytes ? s.totalBytes - s.doneBytes : 0;
            NSString *eta = fmtETA(remain, s.speed);
            _statusLabel.text = [NSString stringWithFormat:@"下载中 · %.2f%% · %@ · 剩 %@",
                                 pct, fmtSpeed(s.speed), eta];
            _detailLabel.text = [NSString stringWithFormat:@"%@  %@ / %@  ·  peer %ld",
                                 name, fmtSize(s.doneBytes), fmtSize(s.totalBytes), (long)s.peerCount];
        }
    } else {
        if (s.state == DLBTSessionStateIdle) _statusLabel.text = @"空闲";
        else if (s.state == DLBTSessionStateCompleted) _statusLabel.text = @"✅ 已完成";
        else if (s.state == DLBTSessionStateFailed) _statusLabel.text = @"❌ 失败";
        else _statusLabel.text = @"⏹ 已停止";
        _detailLabel.text = [NSString stringWithFormat:@"%@  %@ / %@",
                             name, fmtSize(s.doneBytes), fmtSize(s.totalBytes)];
    }
}

- (void)scrollLog {
    if (_logView.text.length > 0) {
        NSRange r = NSMakeRange(_logView.text.length - 1, 1);
        [_logView scrollRangeToVisible:r];
    }
}

#pragma mark - 通知

- (void)onLog:(NSNotification *)n {
    /* 节流：0.15s 内多次日志合并为一次刷新，避免频繁重设 text 造成跳动 */
    if (_logRefreshPending) return;
    _logRefreshPending = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_logRefreshPending = NO;
        strongSelf->_logView.text = [DLBTSession shared].logText;
        [strongSelf scrollLog];
    });
}

- (void)onProgress:(NSNotification *)n {
    [self updateProgressLabels];
}

- (void)onState:(NSNotification *)n {
    [self refreshAll];
}

#pragma mark - 动作

- (void)pasteTapped {
    NSString *clip = [UIPasteboard generalPasteboard].string;
    if (clip.length) {
        _input.text = clip;
    } else {
        [self appendLog:@"剪贴板为空"];
    }
}

- (void)stopTapped {
    [[DLBTSession shared] stop];
}

- (NSString *)downloadsDir {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@"dlbox/downloads"];
}

- (void)pickTorrent {
    NSString *dir = [self downloadsDir];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *items = [fm contentsOfDirectoryAtPath:dir error:nil] ?: @[];
    NSMutableArray *torrents = [NSMutableArray array];
    for (NSString *f in items) {
        if ([f.lowercaseString hasSuffix:@".torrent"]) {
            [torrents addObject:[dir stringByAppendingPathComponent:f]];
        }
    }
    if (torrents.count == 0) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"无种子文件"
            message:@"下载目录里没有 .torrent 文件。可先用 HTTP 下载器下载种子，或用上方输入框粘贴种子链接。"
            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"选择种子"
        message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *path in torrents) {
        NSString *name = path.lastPathComponent;
        [sheet addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            self->_input.text = path;
            [self startWithTorrentData:[NSData dataWithContentsOfFile:path]];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)startDownload {
    NSString *text = [_input.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (text.length == 0) return;
    [_input resignFirstResponder];

    if ([text.lowercaseString hasPrefix:@"magnet:"]) {
        [self appendLog:@"解析 magnet 链接…"];
        NSString *err = nil;
        BOOL ok = [[DLBTSession shared] startWithMagnet:text error:&err];
        if (!ok) {
            [self appendLog:[NSString stringWithFormat:@"❌ %@", err ?: @"启动失败"]];
        }
        return;
    }

    if ([text.lowercaseString hasPrefix:@"http://"] || [text.lowercaseString hasPrefix:@"https://"]) {
        [self appendLog:[NSString stringWithFormat:@"下载种子文件: %@", text]];
        NSURL *url = [NSURL URLWithString:text];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSData *data = [NSData dataWithContentsOfURL:url options:0 error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!data) {
                    [self appendLog:@"❌ 下载种子失败（网络或链接问题）"];
                } else {
                    [self startWithTorrentData:data];
                }
            });
        });
    } else {
        [self startWithTorrentData:[NSData dataWithContentsOfFile:text]];
    }
}

- (void)startWithTorrentData:(NSData *)data {
    if (!data) {
        [self appendLog:@"❌ 无法读取种子文件"];
        return;
    }
    NSString *err = nil;
    BOOL ok = [[DLBTSession shared] startWithTorrentData:data error:&err];
    if (!ok) {
        [self appendLog:[NSString stringWithFormat:@"❌ %@", err ?: @"启动失败"]];
    }
}

- (void)appendLog:(NSString *)line {
    NSString *cur = _logView.text ?: @"";
    _logView.text = [cur stringByAppendingFormat:@"%@\n", line];
    [self scrollLog];
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

@end
