#import "DLFilesViewController.h"

static NSString *DLFmtSize(long long b) {
    if (b <= 0) return @"0 B";
    double v = (double)b;
    NSArray *units = @[@"B", @"KB", @"MB", @"GB", @"TB"];
    int i = 0;
    while (v >= 1024.0 && i < (int)units.count - 1) { v /= 1024.0; i++; }
    return [NSString stringWithFormat:@"%.1f %@", v, units[i]];
}

@interface DLFilesViewController () <UITableViewDataSource, UITableViewDelegate>
@end

@implementation DLFilesViewController {
    UITableView *_tableView;
    NSString *_dir;
    NSArray<NSDictionary *> *_files;
    UILabel *_emptyLabel;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"下载目录";
    self.view.backgroundColor = [UIColor colorWithWhite:0.055 alpha:1.0];

    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    _dir = [docs stringByAppendingPathComponent:@"dlbox/downloads"];

    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.backgroundColor = [UIColor colorWithWhite:0.055 alpha:1.0];
    _tableView.separatorColor = [UIColor colorWithWhite:0.18 alpha:1.0];
    _tableView.rowHeight = 56;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    [self.view addSubview:_tableView];

    _emptyLabel = [[UILabel alloc] init];
    _emptyLabel.text = @"还没有下载完成的文件";
    _emptyLabel.textAlignment = NSTextAlignmentCenter;
    _emptyLabel.font = [UIFont systemFontOfSize:14];
    _emptyLabel.textColor = [UIColor colorWithWhite:0.45 alpha:1.0];
    _emptyLabel.frame = CGRectMake(0, 0, self.view.bounds.size.width, 40);
    [self.view addSubview:_emptyLabel];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refresh];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _emptyLabel.center = CGPointMake(self.view.bounds.size.width / 2.0, self.view.bounds.size.height / 2.0 - 20);
}

- (void)refresh {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *names = [fm contentsOfDirectoryAtPath:_dir error:nil];
    NSMutableArray *arr = [NSMutableArray array];
    for (NSString *name in names) {
        NSString *path = [_dir stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:path isDirectory:&isDir] || isDir) continue;
        NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
        NSNumber *size = attrs[NSFileSize];
        NSDate *date = attrs[NSFileModificationDate];
        [arr addObject:@{
            @"name": name,
            @"path": path,
            @"size": size ?: @0,
            @"date": date ?: [NSDate date],
        }];
    }
    // 按修改时间倒序
    [arr sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"date"] compare:a[@"date"]];
    }];
    _files = arr;
    [_tableView reloadData];
    _emptyLabel.hidden = _files.count > 0;
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _files.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"file";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
        cell.backgroundColor = [UIColor colorWithWhite:0.09 alpha:1.0];
        cell.textLabel.textColor = [UIColor whiteColor];
        cell.textLabel.font = [UIFont systemFontOfSize:15];
        cell.detailTextLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
    }
    NSDictionary *f = _files[indexPath.row];
    cell.textLabel.text = f[@"name"];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyy-MM-dd HH:mm";
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", DLFmtSize([f[@"size"] longLongValue]), [fmt stringFromDate:f[@"date"]]];
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle == UITableViewCellEditingStyleDelete) {
        NSDictionary *f = _files[indexPath.row];
        [[NSFileManager defaultManager] removeItemAtPath:f[@"path"] error:nil];
        [self refresh];
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *f = _files[indexPath.row];
    NSURL *fileURL = [NSURL fileURLWithPath:f[@"path"]];
    UIActivityViewController *avc = [[UIActivityViewController alloc] initWithActivityItems:@[fileURL] applicationActivities:nil];
    [self presentViewController:avc animated:YES completion:nil];
}

@end
