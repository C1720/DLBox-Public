#import "DLTaskCell.h"
#import "DLTask.h"

static NSString *DLFmtBytes(int64_t b) {
    if (b <= 0) return @"0 B";
    double v = (double)b;
    NSArray *units = @[@"B", @"KB", @"MB", @"GB", @"TB"];
    int i = 0;
    while (v >= 1024.0 && i < (int)units.count - 1) { v /= 1024.0; i++; }
    return [NSString stringWithFormat:@"%.1f %@", v, units[i]];
}

static NSString *DLFmtSpeed(int64_t b) {
    if (b <= 0) return @"";
    return [NSString stringWithFormat:@"%@/s", DLFmtBytes(b)];
}

@implementation DLTaskCell {
    UILabel *_titleLabel;
    UILabel *_detailLabel;
    UIProgressView *_progressView;
    UIButton *_actionButton;
    DLTask *_task;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:0.09 alpha:1.0];
        self.contentView.backgroundColor = [UIColor colorWithWhite:0.09 alpha:1.0];
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        _titleLabel.textColor = [UIColor whiteColor];
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;

        _detailLabel = [[UILabel alloc] init];
        _detailLabel.font = [UIFont systemFontOfSize:12];
        _detailLabel.textColor = [UIColor colorWithWhite:0.58 alpha:1.0];

        _progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
        _progressView.trackTintColor = [UIColor colorWithWhite:0.22 alpha:1.0];

        _actionButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _actionButton.tintColor = [UIColor whiteColor];
        _actionButton.backgroundColor = [UIColor colorWithWhite:0.16 alpha:1.0];
        _actionButton.layer.cornerRadius = 20;
        [_actionButton addTarget:self action:@selector(actionTapped) forControlEvents:UIControlEventTouchUpInside];

        [self.contentView addSubview:_titleLabel];
        [self.contentView addSubview:_detailLabel];
        [self.contentView addSubview:_progressView];
        [self.contentView addSubview:_actionButton];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.contentView.bounds.size.width;
    CGFloat h = self.contentView.bounds.size.height;
    CGFloat pad = 16;
    CGFloat actionW = 40;
    _actionButton.frame = CGRectMake(w - actionW - pad, (h - actionW) / 2.0, actionW, actionW);
    CGFloat textW = w - pad * 2 - actionW - 10;
    _titleLabel.frame = CGRectMake(pad, 11, textW, 21);
    _detailLabel.frame = CGRectMake(pad, 35, textW, 16);
    _progressView.frame = CGRectMake(pad, h - 13, textW, 4);
    _progressView.layer.cornerRadius = 2;
    _progressView.layer.masksToBounds = YES;
}

- (void)configureWithTask:(DLTask *)task {
    _task = task;
    _titleLabel.text = task.fileName;

    NSMutableString *detail = [NSMutableString stringWithString:task.stateName];
    if (task.state == DLTaskStateRunning) {
        if (task.totalBytes > 0) {
            int pct = (int)(task.progress * 100);
            [detail appendFormat:@" · %@ / %@ (%d%%)", DLFmtBytes(task.receivedBytes), DLFmtBytes(task.totalBytes), pct];
        } else {
            [detail appendFormat:@" · %@", DLFmtBytes(task.receivedBytes)];
        }
        NSString *speed = DLFmtSpeed(task.speed);
        if (speed.length) [detail appendFormat:@" · %@", speed];
        if (task.segmentCount > 1) [detail appendFormat:@" · %ld 段", (long)task.segmentCount];
    } else if (task.state == DLTaskStateCompleted) {
        [detail appendFormat:@" · %@", DLFmtBytes(task.receivedBytes)];
    } else if (task.state == DLTaskStateFailed) {
        if (task.errorMessage.length) [detail appendFormat:@" · %@", task.errorMessage];
    } else if (task.state == DLTaskStatePaused) {
        if (task.totalBytes > 0) {
            int pct = (int)(task.progress * 100);
            [detail appendFormat:@" · %@ / %@ (%d%%)", DLFmtBytes(task.receivedBytes), DLFmtBytes(task.totalBytes), pct];
        }
    }
    _detailLabel.text = detail;

    if (task.state == DLTaskStateRunning || task.state == DLTaskStateWaiting) {
        _progressView.progress = (float)task.progress;
        _progressView.hidden = NO;
        _progressView.progressTintColor = [UIColor colorWithRed:0.20 green:0.65 blue:1.0 alpha:1.0];
        [_actionButton setImage:[UIImage systemImageNamed:@"pause.fill"] forState:UIControlStateNormal];
        _actionButton.hidden = NO;
    } else if (task.state == DLTaskStatePaused || task.state == DLTaskStateFailed) {
        _progressView.progress = (float)task.progress;
        _progressView.hidden = NO;
        _progressView.progressTintColor = task.state == DLTaskStateFailed
            ? [UIColor colorWithRed:0.9 green:0.35 blue:0.3 alpha:1.0]
            : [UIColor colorWithWhite:0.5 alpha:1.0];
        [_actionButton setImage:[UIImage systemImageNamed:@"play.fill"] forState:UIControlStateNormal];
        _actionButton.hidden = NO;
    } else { // completed
        _progressView.hidden = YES;
        _actionButton.hidden = YES;
    }
}

- (void)actionTapped {
    if (self.onAction && _task) self.onAction(_task);
}

@end
