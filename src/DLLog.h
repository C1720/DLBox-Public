#import <Foundation/Foundation.h>

/* DLBox 持久化诊断日志。
 *
 * 目的：闪退 / 被系统杀掉之后还能留下现场。
 * - 所有 BT 引擎日志、崩溃信号、内存占用都追加到 Documents/dlbox/logs/dlbox.log
 * - 每次 write 直接落盘（不做内存缓冲），SIGKILL 之外的崩溃都能留下痕迹
 * - 超过 1MB 自动裁剪前半，避免无限增长
 */
@interface DLLog : NSObject

/* App 启动时调用一次：建目录、装崩溃处理器、记录版本/内存/上次是否异常退出。 */
+ (void)setup;

/* 追加一行（自动加时间戳）。线程安全，可从任意线程调用。 */
+ (void)write:(NSString *)line;

+ (NSString *)logPath;
/* 读取日志（只取尾部 200KB，够贴给助手看）。 */
+ (NSString *)content;
+ (void)clear;

/* 当前进程内存占用描述，如 "128.4MB"。 */
+ (NSString *)memoryString;

/* 正常退出时调用，用于区分「主动退出」和「崩溃」。 */
+ (void)markCleanExit;

@end
