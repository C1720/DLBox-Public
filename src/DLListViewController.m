#import "DLListViewController.h"
#import "DLDownloadEngine.h"
#import "DLTask.h"
#import "DLTaskCell.h"
#import "DLAddViewController.h"

static NSString * const kCellId = @"DLTaskCell";

@interface DLListViewController () <UITableViewDataSource, UITableViewDelegate>
@end

@implementation DLListViewController {
    UITableView *_tableView;
    NSArray<DLTask *> *_tasks;
    UILabel *_emptyLabel;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"DLBox";
    self.view.backgroundColor = [UIColor colorWithWhite:0.055 alpha:1.0];

    UIBarButtonItem *add = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                                         target:self action:@selector(addTapped)];
    self.navigationItem.rightBarButtonItem = add;

    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.backgroundColor = [UIColor colorWithWhite:0.055 alpha:1.0];
    _tableView.separatorColor = [UIColor colorWithWhite:0.16 alpha:1.0];
    _tableView.separatorInset = UIEdgeInsetsMake(0, 16, 0, 0);
    _tableView.rowHeight = 78;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    [_tableView registerClass:[DLTaskCell class] forCellReuseIdentifier:kCellId];
    [self.view addSubview:_tableView];

    _emptyLabel = [[UILabel alloc] init];
    _emptyLabel.text = @"暂无下载任务\n点右上角 + 添加链接";
    _emptyLabel.numberOfLines = 0;
    _emptyLabel.textAlignment = NSTextAlignmentCenter;
    _emptyLabel.font = [UIFont systemFontOfSize:14];
    _emptyLabel.textColor = [UIColor colorWithWhite:0.45 alpha:1.0];
    _emptyLabel.frame = CGRectMake(0, 0, self.view.bounds.size.width, 60);
    [self.view addSubview:_emptyLabel];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reload)
                                                 name:DLDownloadTasksChangedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshVisible)
                                                 name:DLDownloadProgressNotification object:nil];

    [self reload];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _emptyLabel.center = CGPointMake(self.view.bounds.size.width / 2.0,
                                     self.view.bounds.size.height / 2.0 - 20);
}

- (void)refreshTasks {
    _tasks = [[DLDownloadEngine sharedEngine] allTasks];
}

- (void)reload {
    [self refreshTasks];
    [_tableView reloadData];
    _emptyLabel.hidden = _tasks.count > 0;
}

- (void)refreshVisible {
    [self refreshTasks];
    for (DLTaskCell *cell in _tableView.visibleCells) {
        NSIndexPath *ip = [_tableView indexPathForCell:cell];
        if (ip && ip.row < _tasks.count) [cell configureWithTask:_tasks[ip.row]];
    }
    _emptyLabel.hidden = _tasks.count > 0;
}

#pragma mark - Actions

- (void)addTapped {
    DLAddViewController *vc = [[DLAddViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)handleActionForTask:(DLTask *)task {
    if (task.state == DLTaskStateRunning || task.state == DLTaskStateWaiting) {
        [[DLDownloadEngine sharedEngine] pauseTask:task.taskId];
    } else if (task.state == DLTaskStatePaused || task.state == DLTaskStateFailed) {
        [[DLDownloadEngine sharedEngine] resumeTask:task.taskId];
    }
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _tasks.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    DLTaskCell *cell = [tableView dequeueReusableCellWithIdentifier:kCellId forIndexPath:indexPath];
    DLTask *t = _tasks[indexPath.row];
    [cell configureWithTask:t];
    __weak typeof(self) weakSelf = self;
    cell.onAction = ^(DLTask *task) {
        [weakSelf handleActionForTask:task];
    };
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle == UITableViewCellEditingStyleDelete) {
        DLTask *t = _tasks[indexPath.row];
        [[DLDownloadEngine sharedEngine] removeTask:t.taskId];
    }
}

@end
