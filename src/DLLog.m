#import "DLLog.h"
#import <pthread/pthread.h>
#import <unistd.h>
#import <fcntl.h>
#import <signal.h>
#import <string.h>
#import <sys/stat.h>
#import <sys/time.h>
#import <sys/sysctl.h>
#import <mach/mach.h>
#import <UIKit/UIKit.h>

static char g_logDir[1024];
static char g_logPath[1024];
static int g_fd = -1;
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static const off_t kMaxBytes = 1024 * 1024;   /* 单文件 1MB，超了裁掉前半 */

static void ts_prefix(char *out, size_t n) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    struct tm tm;
    localtime_r(&tv.tv_sec, &tm);
    snprintf(out, n, "[%02d:%02d:%02d.%03d] ",
             tm.tm_hour, tm.tm_min, tm.tm_sec, (int)(tv.tv_usec / 1000));
}

/* 不加锁的原始写，信号处理器里也能用 */
static void raw_write(const char *s, size_t len) {
    if (g_fd < 0 || !s || len == 0) return;
    ssize_t r = write(g_fd, s, len);
    (void)r;
}

static void rotate_locked(void) {
    if (g_fd < 0) return;
    struct stat st;
    if (fstat(g_fd, &st) != 0) return;
    if (st.st_size <= kMaxBytes) return;
    char old[1100];
    snprintf(old, sizeof(old), "%s.old", g_logPath);
    close(g_fd);
    unlink(old);
    rename(g_logPath, old);
    g_fd = open(g_logPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
}

static void crash_handler(int sig) {
    char buf[512];
    char ts[40];
    ts_prefix(ts, sizeof(ts));
    const char *name = "未知信号";
    switch (sig) {
        case SIGSEGV: name = "SIGSEGV 段错误（越界/野指针）"; break;
        case SIGABRT: name = "SIGABRT 主动中止（断言/未捕获异常）"; break;
        case SIGBUS:  name = "SIGBUS 总线错误"; break;
        case SIGILL:  name = "SIGILL 非法指令"; break;
        case SIGFPE:  name = "SIGFPE 算术异常"; break;
        case SIGPIPE: name = "SIGPIPE 写已断开连接"; break;
    }
    int n = snprintf(buf, sizeof(buf), "%s[崩溃] %s (signal %d)\n", ts, name, sig);
    if (n > 0) raw_write(buf, (size_t)n);
    signal(sig, SIG_DFL);
    raise(sig);
}

static void uncaught_handler(NSException *e) {
    NSString *desc = [NSString stringWithFormat:@"[崩溃] 未捕获异常 %@: %@\n%@",
                      e.name, e.reason,
                      [e.callStackSymbols componentsJoinedByString:@"\n"]];
    [DLLog write:desc];
}

@implementation DLLog

+ (void)setup {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!docs) return;
    NSString *dir = [docs stringByAppendingPathComponent:@"dlbox/logs"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    strncpy(g_logDir, dir.UTF8String, sizeof(g_logDir) - 1);
    NSString *p = [dir stringByAppendingPathComponent:@"dlbox.log"];
    strncpy(g_logPath, p.UTF8String, sizeof(g_logPath) - 1);

    g_fd = open(g_logPath, O_WRONLY | O_CREAT | O_APPEND, 0644);

    /* ★ 最重要的一行：Darwin 上向已 RST 的 TCP 连接 send() 会发 SIGPIPE，
     * 默认动作是终止进程 —— 这就是「下载到一半闪退」的头号原因。
     * socket 层已用 SO_NOSIGPIPE 逐条关掉，这里再全局兜底。 */
    signal(SIGPIPE, SIG_IGN);

    NSSetUncaughtExceptionHandler(&uncaught_handler);
    signal(SIGSEGV, crash_handler);
    signal(SIGABRT, crash_handler);
    signal(SIGBUS, crash_handler);
    signal(SIGILL, crash_handler);
    signal(SIGFPE, crash_handler);

    /* 上次是否正常退出 */
    NSString *flag = [dir stringByAppendingPathComponent:@"running.flag"];
    if ([fm fileExistsAtPath:flag]) {
        [self write:@"⚠️ 上次运行未正常结束（崩溃或被系统杀掉，下面是本次启动）"];
    }
    [@"running" writeToFile:flag atomically:YES encoding:NSUTF8StringEncoding error:nil];

    char machine[64] = {0};
    size_t mlen = sizeof(machine) - 1;
    sysctlbyname("hw.machine", machine, &mlen, NULL, 0);
    NSString *ver = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";

    [self write:@"==================== DLBox 启动 ===================="];
    [self write:[NSString stringWithFormat:@"版本 %@ · 机型 %s · 系统 %@",
                 ver, machine, [[UIDevice currentDevice] systemVersion]]];
    [self write:[NSString stringWithFormat:@"内存 %@ · 日志 %@", [self memoryString], p]];

    /* 每 15 秒记一次内存水位：被系统 OOM 杀掉时没有崩溃日志，
     * 但能从这里看到闪退前内存冲到多少 */
    static dispatch_source_t timer;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_queue_t q = dispatch_queue_create("dev.dlbox.app.logbeat", DISPATCH_QUEUE_SERIAL);
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
        dispatch_source_set_timer(timer,
                                  dispatch_time(DISPATCH_TIME_NOW, 15ull * NSEC_PER_SEC),
                                  15ull * NSEC_PER_SEC, 5ull * NSEC_PER_SEC);
        dispatch_source_set_event_handler(timer, ^{
            [DLLog write:[NSString stringWithFormat:@"[心跳] 内存 %@", [DLLog memoryString]]];
        });
        dispatch_resume(timer);
    });
}

+ (void)write:(NSString *)line {
    if (line.length == 0) return;
    NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (!d) return;
    char ts[40];
    ts_prefix(ts, sizeof(ts));
    pthread_mutex_lock(&g_mu);
    rotate_locked();
    raw_write(ts, strlen(ts));
    raw_write((const char *)d.bytes, d.length);
    raw_write("\n", 1);
    pthread_mutex_unlock(&g_mu);
}

+ (NSString *)logPath {
    return g_logPath[0] ? [NSString stringWithUTF8String:g_logPath] : nil;
}

+ (NSString *)content {
    NSString *p = [self logPath];
    if (!p) return @"";
    NSData *d = [NSData dataWithContentsOfFile:p];
    if (!d) return @"";
    /* 只取尾部 200KB */
    NSUInteger maxLen = 200 * 1024;
    if (d.length > maxLen) d = [d subdataWithRange:NSMakeRange(d.length - maxLen, maxLen)];
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    return s ?: @"（日志解码失败）";
}

+ (void)clear {
    pthread_mutex_lock(&g_mu);
    if (g_fd >= 0) { close(g_fd); g_fd = -1; }
    if (g_logPath[0]) truncate(g_logPath, 0);
    g_fd = open(g_logPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    pthread_mutex_unlock(&g_mu);
    [self write:@"===== 日志已清空 ====="];
}

+ (NSString *)memoryString {
    struct task_vm_info info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t kr = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count);
    if (kr != KERN_SUCCESS) return @"未知";
    return [NSString stringWithFormat:@"%.1f MB", (double)info.phys_footprint / 1048576.0];
}

+ (void)markCleanExit {
    if (!g_logDir[0]) return;
    NSString *flag = [[NSString stringWithUTF8String:g_logDir] stringByAppendingPathComponent:@"running.flag"];
    [[NSFileManager defaultManager] removeItemAtPath:flag error:nil];
    [self write:[NSString stringWithFormat:@"===== 正常退出 · 内存 %@ =====", [self memoryString]]];
}

@end
