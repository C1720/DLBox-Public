#import <UIKit/UIKit.h>

@class DLTask;

NS_ASSUME_NONNULL_BEGIN

@interface DLTaskCell : UITableViewCell

@property (nonatomic, copy, nullable) void (^onAction)(DLTask *task);

- (void)configureWithTask:(DLTask *)task;

@end

NS_ASSUME_NONNULL_END
