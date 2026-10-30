#import "DLCrawlViewController.h"
#import "DLCrawler.h"
#import "DLDownloadEngine.h"
#import "DLLog.h"

@interface DLCrawlViewController () <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate>
@end

@implementation DLCrawlViewController {
    UITableView *_tableView;
    UILabel *_statusLabel;
    UIBarButtonItem *_enqueueItem;

    UITextField *_urlField;
    UISwitch *_sameSwitch;
    UISwitch *_imageSwitch;
    UITextField *_extField;
    UITextField *_kwField;

    NSArray<DLCrawlItem *> *_items;
    NSMutableSet<NSString *> *_selected;
    BOOL _busy;
    BOOL _usedWebView;
    NSString *_statusText;
}

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _items = @[];
        _selected = [NSMutableSet set];
        _statusText = @"贴一个网页地址，点右上角「开始抓取」";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"抓取";
    self.view.backgroundColor = [UIColor colorWithWhite:0.055 alpha:1.0];

    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    _tableView.backgroundColor = [UIColor colorWithWhite:0.055 alpha:1.0];
    _tableView.separatorColor = [UIColor colorWithWhite:0.16 alpha:1.0];
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:_tableView];

    UIToolbar *toolbar = [[UIToolbar alloc] init];
    toolbar.translatesAutoresizingMaskIntoConstraints = NO;
    toolbar.barStyle = UIBarStyleBlack;
    toolbar.translucent = NO;
    _enqueueItem = [[UIBarButtonItem alloc] initWithTitle:@"入队"
                                                    style:UIBarButtonItemStyleDone
                                                   target:self
                                                   action:@selector(enqueueTapped)];
    _enqueueItem.enabled = NO;
    UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                                          target:nil action:nil];
    toolbar.items = @[flex, _enqueueItem];
    [self.view addSubview:toolbar];

    [NSLayoutConstraint activateConstraints:@[
        [_tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_tableView.bottomAnchor constraintEqualToAnchor:toolbar.topAnchor],
        [toolbar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [toolbar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [toolbar.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
    ]];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"开始抓取" style:UIBarButtonItemStyleDone
                                        target:self action:@selector(crawlTapped)];
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"全选" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(toggleSelectAll)];

    _urlField = [self makeFieldWithPlaceholder:@"https://example.com/page.html" keyboard:UIKeyboardTypeURL];
    _extField = [self makeFieldWithPlaceholder:@"mp4,mkv,zip（留空=全部）" keyboard:UIKeyboardTypeDefault];
    _kwField = [self makeFieldWithPlaceholder:@"文件名包含…（可空）" keyboard:UIKeyboardTypeDefault];

    _sameSwitch = [[UISwitch alloc] init];
    _sameSwitch.on = NO;
    _imageSwitch = [[UISwitch alloc] init];
    _imageSwitch.on = NO;

    /* 剪贴板里像是链接的话，自动填进去 */
    NSString *clip = [UIPasteboard generalPasteboard].string;
    if (clip.length && ([clip hasPrefix:@"http://"] || [clip hasPrefix:@"https://"]) && clip.length < 2000) {
        _urlField.text = clip;
    }

    _statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 44)];
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    _statusLabel.numberOfLines = 2;
    _statusLabel.font = [UIFont systemFontOfSize:12];
    _statusLabel.textColor = [UIColor colorWithWhite:0.5 alpha:1.0];
    _statusLabel.text = _statusText;
    _tableView.tableFooterView = _statusLabel;

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissKeyboard)];
    tap.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:tap];

    [self refreshStatus];
}

#pragma mark - UI 小工具

- (UITextField *)makeFieldWithPlaceholder:(NSString *)placeholder keyboard:(UIKeyboardType)keyboard {
    UITextField *f = [[UITextField alloc] initWithFrame:CGRectMake(16, 0, 320, 44)];
    f.placeholder = placeholder;
    f.keyboardType = keyboard;
    f.autocapitalizationType = UITextAutocapitalizationTypeNone;
    f.autocorrectionType = UITextAutocorrectionTypeNo;
    f.clearButtonMode = UITextFieldViewModeWhileEditing;
    f.returnKeyType = UIReturnKeyDone;
    f.delegate = self;
    f.textColor = [UIColor whiteColor];
    f.font = [UIFont systemFontOfSize:15];
    return f;
}

- (void)dismissKeyboard {
    [self.view endEditing:YES];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)refreshStatus {
    _statusLabel.text = _statusText;
    NSUInteger total = _items.count;
    NSUInteger sel = _selected.count;
    _enqueueItem.title = sel > 0
        ? [NSString stringWithFormat:@"入队 (%lu/%lu)", (unsigned long)sel, (unsigned long)total]
        : [NSString stringWithFormat:@"入队 (0/%lu)", (unsigned long)total];
    _enqueueItem.enabled = (sel > 0) && !_busy;
}

- (void)setStatus:(NSString *)text {
    _statusText = text;
    [self refreshStatus];
}

#pragma mark - 抓取

- (void)crawlTapped {
    if (_busy) return;
    [self dismissKeyboard];

    DLCrawlOptions *opt = [[DLCrawlOptions alloc] init];
    opt.sameDomainOnly = _sameSwitch.on;
    opt.includeImages = _imageSwitch.on;
    opt.keyword = _kwField.text;
    opt.extensions = [self parseExtensions:_extField.text];

    _busy = YES;
    _usedWebView = NO;
    [_selected removeAllObjects];
    _items = @[];
    [_tableView reloadData];
    [self setStatus:@"抓取中…"];
    self.navigationItem.rightBarButtonItem.enabled = NO;

    __weak typeof(self) weakSelf = self;
    /* 兜底：45 秒还没回调就把界面解锁，避免永远卡在「抓取中…」 */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(45 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) s = weakSelf;
        if (s && s->_busy) {
            s->_busy = NO;
            s.navigationItem.rightBarButtonItem.enabled = YES;
            [s setStatus:@"抓取超时：网络没响应。检查网络后重试"];
            [DLLog write:@"[Crawl] 45s 无回调，强制解锁界面"];
        }
    });

    [DLCrawler crawlURLString:_urlField.text options:opt completion:^(NSArray<DLCrawlItem *> *items,
                                                                     NSString *errorMessage,
                                                                     BOOL usedWebView) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        self->_busy = NO;
        self->_usedWebView = usedWebView;
        self->_items = items ?: @[];
        self->_selected = [NSMutableSet set];
        self.navigationItem.rightBarButtonItem.enabled = YES;

        if (errorMessage.length) {
            [self setStatus:errorMessage];
        } else {
            NSString *src = usedWebView ? @"（WebView 渲染）" : @"";
            [self setStatus:[NSString stringWithFormat:@"找到 %lu 条可下载链接%@",
                             (unsigned long)self->_items.count, src]];
        }
        [self->_tableView reloadData];
        [DLLog write:[NSString stringWithFormat:@"[Crawl] 完成：%lu 条，error=%@",
                      (unsigned long)self->_items.count, errorMessage ?: @"无"]];
    }];
}

- (NSArray<NSString *> *)parseExtensions:(NSString *)text {
    if (text.length == 0) return @[];
    NSArray *parts = [text componentsSeparatedByCharactersInSet:
                      [NSCharacterSet characterSetWithCharactersInString:@",，;； "]];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *p in parts) {
        NSString *v = [p stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        v = [v stringByReplacingOccurrencesOfString:@"*." withString:@""];
        v = [v stringByReplacingOccurrencesOfString:@"." withString:@""];
        if (v.length) [out addObject:v.lowercaseString];
    }
    return out;
}

#pragma mark - 选择 / 入队

- (void)toggleSelectAll {
    if (_items.count == 0) return;
    if (_selected.count == _items.count) {
        [_selected removeAllObjects];
    } else {
        for (DLCrawlItem *it in _items) [_selected addObject:it.urlString];
    }
    self.navigationItem.leftBarButtonItem.title = (_selected.count == _items.count && _items.count > 0) ? @"取消全选" : @"全选";
    [_tableView reloadData];
    [self refreshStatus];
}

- (void)enqueueTapped {
    if (_selected.count == 0) return;
    NSInteger ok = 0;
    NSInteger fail = 0;
    for (DLCrawlItem *it in _items) {
        if (![_selected containsObject:it.urlString]) continue;
        NSURL *url = [NSURL URLWithString:it.urlString];
        NSString *fileName = it.name.length ? it.name : nil;
        NSString *taskId = url ? [[DLDownloadEngine sharedEngine] enqueueURL:url fileName:fileName] : nil;
        if (taskId) ok++; else fail++;
    }
    [DLLog write:[NSString stringWithFormat:@"[Crawl] 入队 %ld 条，失败 %ld 条", (long)ok, (long)fail]];

    NSString *msg = [NSString stringWithFormat:@"已加入 %ld 条下载任务%@",
                     (long)ok, fail > 0 ? [NSString stringWithFormat:@"，%ld 条链接无效被跳过", (long)fail] : @""];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
                                                                   message:msg
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"去下载列表" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        self.tabBarController.selectedIndex = 0;
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"留在这" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];

    [_selected removeAllObjects];
    [_tableView reloadData];
    [self refreshStatus];
}

#pragma mark - UITableView

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0: return 1;              // URL
        case 1: return 4;              // 同域 / 含图片 / 扩展名 / 关键字
        case 2: return _items.count;   // 结果
    }
    return 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return @"网页地址";
        case 1: return @"过滤";
        case 2: return [NSString stringWithFormat:@"结果（%lu 条）", (unsigned long)_items.count];
    }
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 2) {
        return _items.count ? @"勾选后点底部「入队」，链接会直接进入下载队列。" : nil;
    }
    return nil;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return (indexPath.section == 2) ? 54 : 46;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                                   reuseIdentifier:nil];
    cell.backgroundColor = [UIColor colorWithWhite:0.09 alpha:1.0];
    cell.textLabel.textColor = [UIColor whiteColor];
    cell.detailTextLabel.textColor = [UIColor colorWithWhite:0.5 alpha:1.0];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    if (indexPath.section == 0) {
        _urlField.frame = CGRectMake(16, 0, cell.contentView.bounds.size.width - 32, 46);
        _urlField.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [cell.contentView addSubview:_urlField];
    } else if (indexPath.section == 1) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"只抓同域链接";
            _sameSwitch.frame = CGRectMake(cell.contentView.bounds.size.width - 67, 7, 51, 31);
            _sameSwitch.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
            [cell.contentView addSubview:_sameSwitch];
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"包含图片";
            _imageSwitch.frame = CGRectMake(cell.contentView.bounds.size.width - 67, 7, 51, 31);
            _imageSwitch.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
            [cell.contentView addSubview:_imageSwitch];
        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"扩展名";
            _extField.frame = CGRectMake(cell.contentView.bounds.size.width * 0.38, 0,
                                         cell.contentView.bounds.size.width * 0.58, 46);
            _extField.autoresizingMask = UIViewAutoresizingFlexibleWidth;
            _extField.textAlignment = NSTextAlignmentRight;
            [cell.contentView addSubview:_extField];
        } else {
            cell.textLabel.text = @"关键字";
            _kwField.frame = CGRectMake(cell.contentView.bounds.size.width * 0.38, 0,
                                        cell.contentView.bounds.size.width * 0.58, 46);
            _kwField.autoresizingMask = UIViewAutoresizingFlexibleWidth;
            _kwField.textAlignment = NSTextAlignmentRight;
            [cell.contentView addSubview:_kwField];
        }
    } else {
        DLCrawlItem *item = _items[indexPath.row];
        cell.textLabel.text = item.name;
        cell.textLabel.font = [UIFont systemFontOfSize:15];
        cell.textLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        NSString *mark = item.crossDomain ? @"跨域" : @"同域";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@ · %@", item.category, mark, item.ext.length ? item.ext : @"-"];
        cell.accessoryType = [_selected containsObject:item.urlString]
            ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        cell.accessoryView = nil;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section != 2) return;
    DLCrawlItem *item = _items[indexPath.row];
    if ([_selected containsObject:item.urlString]) [_selected removeObject:item.urlString];
    else [_selected addObject:item.urlString];
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
    self.navigationItem.leftBarButtonItem.title = (_selected.count == _items.count && _items.count > 0) ? @"取消全选" : @"全选";
    [self refreshStatus];
}

@end
