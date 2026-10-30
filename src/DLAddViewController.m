#import "DLAddViewController.h"
#import "DLDownloadEngine.h"
#import "DLSettings.h"

@interface DLAddViewController () <UITextFieldDelegate>
@end

@implementation DLAddViewController {
    UIScrollView *_scroll;
    UITextField *_urlField;
    UITextField *_nameField;
    UILabel *_hintLabel;
    UILabel *_footLabel;
    UIButton *_submitButton;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"新建下载";
    self.view.backgroundColor = [UIColor colorWithWhite:0.07 alpha:1.0];

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                                                          target:self action:@selector(cancel)];

    _scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    _scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _scroll.alwaysBounceVertical = YES;
    _scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:_scroll];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissKeyboard)];
    tap.cancelsTouchesInView = NO;
    [_scroll addGestureRecognizer:tap];

    [self buildForm];
    [self fillFromPasteboard];
    [self setupKeyboardAvoidance];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutForm];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [_urlField becomeFirstResponder];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Build

- (UITextField *)fieldWithPlaceholder:(NSString *)ph {
    UITextField *tf = [[UITextField alloc] init];
    tf.backgroundColor = [UIColor colorWithWhite:0.14 alpha:1.0];
    tf.layer.cornerRadius = 10;
    tf.layer.masksToBounds = YES;
    tf.textColor = [UIColor whiteColor];
    tf.font = [UIFont systemFontOfSize:16];
    tf.attributedPlaceholder = [[NSAttributedString alloc] initWithString:ph
                                                               attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:0.42 alpha:1.0]}];
    tf.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 14, 1)];
    tf.leftViewMode = UITextFieldViewModeAlways;
    tf.rightView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 14, 1)];
    tf.rightViewMode = UITextFieldViewModeAlways;
    tf.autocorrectionType = UITextAutocorrectionTypeNo;
    tf.delegate = self;
    return tf;
}

- (void)buildForm {
    _urlField = [self fieldWithPlaceholder:@"https://example.com/file.zip"];
    _urlField.keyboardType = UIKeyboardTypeURL;
    _urlField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _urlField.returnKeyType = UIReturnKeyNext;

    _nameField = [self fieldWithPlaceholder:@"文件名（可选，留空自动识别）"];
    _nameField.returnKeyType = UIReturnKeyDone;

    _hintLabel = [[UILabel alloc] init];
    _hintLabel.numberOfLines = 0;
    _hintLabel.font = [UIFont systemFontOfSize:13];
    _hintLabel.textColor = [UIColor colorWithRed:0.95 green:0.45 blue:0.4 alpha:1.0];
    _hintLabel.hidden = YES;

    _submitButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _submitButton.backgroundColor = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0];
    _submitButton.layer.cornerRadius = 12;
    _submitButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [_submitButton setTitle:@"开始下载" forState:UIControlStateNormal];
    [_submitButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [_submitButton addTarget:self action:@selector(submit) forControlEvents:UIControlEventTouchUpInside];

    [_scroll addSubview:_urlField];
    [_scroll addSubview:_nameField];
    [_scroll addSubview:_hintLabel];
    [_scroll addSubview:_submitButton];

    _footLabel = [[UILabel alloc] init];
    _footLabel.numberOfLines = 0;
    _footLabel.font = [UIFont systemFontOfSize:12];
    _footLabel.textColor = [UIColor colorWithWhite:0.45 alpha:1.0];
    _footLabel.text = @"支持 HTTP / HTTPS 直链。\n文件名留空时自动从链接识别；分段数与限速可在「设置」中调整。";
    [_scroll addSubview:_footLabel];
}

- (void)layoutForm {
    if (!_urlField) return;
    CGFloat w = _scroll.bounds.size.width;
    if (w <= 0) return;
    CGFloat pad = 18;
    CGFloat fieldH = 50;
    CGFloat y = 28;

    _urlField.frame = CGRectMake(pad, y, w - pad * 2, fieldH);
    y += fieldH + 22;
    _nameField.frame = CGRectMake(pad, y, w - pad * 2, fieldH);
    y += fieldH + 14;

    CGFloat hintH = 0;
    if (!_hintLabel.hidden && _hintLabel.text.length > 0) {
        hintH = [_hintLabel sizeThatFits:CGSizeMake(w - pad * 2, CGFLOAT_MAX)].height;
        hintH = MAX(hintH, 18);
    }
    _hintLabel.frame = CGRectMake(pad, y, w - pad * 2, hintH);
    y += hintH + (hintH > 0 ? 14 : 0);

    _submitButton.frame = CGRectMake(pad, y, w - pad * 2, 50);
    y += 50 + 20;

    CGFloat footH = 0;
    if (_footLabel) {
        footH = [_footLabel sizeThatFits:CGSizeMake(w - pad * 2, CGFLOAT_MAX)].height;
        _footLabel.frame = CGRectMake(pad, y, w - pad * 2, footH);
        y += footH + 30;
    }

    _scroll.contentSize = CGSizeMake(w, y);
}

#pragma mark - Keyboard

- (void)setupKeyboardAvoidance {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillChange:)
                                                 name:UIKeyboardWillChangeFrameNotification
                                               object:nil];
}

- (void)keyboardWillChange:(NSNotification *)note {
    CGRect end = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect kbInView = [self.view convertRect:end fromView:nil];
    CGFloat kbH = CGRectGetHeight(self.view.bounds) - kbInView.origin.y;
    if (kbH < 0) kbH = 0;
    UIEdgeInsets insets = UIEdgeInsetsMake(0, 0, kbH, 0);
    NSTimeInterval dur = [note.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    [UIView animateWithDuration:(dur > 0 ? dur : 0.25) animations:^{
        self->_scroll.contentInset = insets;
        self->_scroll.scrollIndicatorInsets = insets;
    }];
}

- (void)dismissKeyboard {
    [self.view endEditing:YES];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    if (textField == _urlField) {
        [_nameField becomeFirstResponder];
    } else {
        [textField resignFirstResponder];
    }
    return YES;
}

#pragma mark - Actions

- (void)fillFromPasteboard {
    NSString *paste = [UIPasteboard generalPasteboard].string;
    if (paste.length == 0) return;
    NSString *t = [paste stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([t.lowercaseString hasPrefix:@"http://"] || [t.lowercaseString hasPrefix:@"https://"]) {
        _urlField.text = t;
    }
}

- (void)showHint:(NSString *)text {
    _hintLabel.text = text;
    _hintLabel.hidden = (text.length == 0);
    [self.view setNeedsLayout];
}

- (void)cancel {
    [self.view endEditing:YES];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)submit {
    [self.view endEditing:YES];

    NSString *urlStr = [_urlField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (urlStr.length == 0) { [self showHint:@"请输入下载链接"]; return; }
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url || !url.scheme) { [self showHint:@"链接格式不正确"]; return; }
    NSString *scheme = url.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) {
        [self showHint:@"仅支持 http / https 链接"];
        return;
    }
    if ([scheme isEqualToString:@"http"] && ![DLSettings shared].allowHTTP) {
        [self showHint:@"已在「设置」中禁用 HTTP 明文下载，请改用 https 或开启开关"];
        return;
    }

    NSString *name = [_nameField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *taskId = [[DLDownloadEngine sharedEngine] enqueueURL:url fileName:(name.length ? name : nil)];
    if (taskId) {
        [self dismissViewControllerAnimated:YES completion:nil];
    } else {
        [self showHint:@"添加失败，请检查链接"];
    }
}

@end
