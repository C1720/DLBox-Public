#import "DLBTLib.h"
#import "DLLog.h"

#include <atomic>
#include <memory>
#include <string>
#include <vector>

#include <libtorrent/session.hpp>
#include <libtorrent/session_params.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/load_torrent.hpp>
#include <libtorrent/read_resume_data.hpp>
#include <libtorrent/write_resume_data.hpp>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/torrent_status.hpp>
#include <libtorrent/bencode.hpp>
#include <libtorrent/version.hpp>

NSString *const DLBTTasksChangedNotification = @"DLBTTasksChangedNotification";

@implementation DLBTTask
@end

static NSString *HashToHex(lt::sha1_hash const &h) {
    return [NSString stringWithUTF8String:h.to_string().c_str()];
}

static NSString *ErrToStr(lt::error_code const &ec) {
    return [NSString stringWithUTF8String:ec.message().c_str()];
}

@implementation DLBTLib {
    std::unique_ptr<lt::session> _session;
    std::atomic<bool> _running;
    NSThread *_alertThread;
    NSString *_btDir;      // Documents/dlbox/bt      （元数据 / fastresume）
    NSString *_dlDir;      // Documents/dlbox/downloads（下载内容）
    NSRecursiveLock *_lock;
}

+ (instancetype)shared {
    static DLBTLib *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[DLBTLib alloc] init]; });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _running = false;
        _lock = [[NSRecursiveLock alloc] init];
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        _btDir = [docs stringByAppendingPathComponent:@"dlbox/bt"];
        _dlDir = [docs stringByAppendingPathComponent:@"dlbox/downloads"];
    }
    return self;
}

- (BOOL)isStarted { return _session != nullptr; }
- (NSString *)downloadDirectory { return _dlDir; }
- (NSString *)versionString {
    return [NSString stringWithFormat:@"libtorrent %d.%d.%d", LIBTORRENT_VERSION_MAJOR, LIBTORRENT_VERSION_MINOR, LIBTORRENT_VERSION_TINY];
}

#pragma mark - 生命周期

- (void)start {
    if (_session) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:_btDir withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:_dlDir withIntermediateDirectories:YES attributes:nil error:nil];

    lt::settings_pack sp;
    sp.set_str(lt::settings_pack::listen_interfaces, "0.0.0.0:6881,[::]:6881");
    sp.set_int(lt::settings_pack::alert_mask, 0x7fffffff);  // 全部类别
    sp.set_bool(lt::settings_pack::enable_dht, true);
    sp.set_bool(lt::settings_pack::enable_lsd, true);
    sp.set_bool(lt::settings_pack::enable_upnp, true);
    sp.set_bool(lt::settings_pack::enable_natpmp, true);
    sp.set_str(lt::settings_pack::user_agent, "DLBox/0.5.0 libtorrent/2.0.11");
    sp.set_int(lt::settings_pack::active_downloads, 8);
    sp.set_int(lt::settings_pack::active_seeds, 8);
    sp.set_int(lt::settings_pack::active_limit, 16);
    sp.set_int(lt::settings_pack::connections_limit, 200);
    sp.set_bool(lt::settings_pack::announce_to_all_trackers, true);
    sp.set_bool(lt::settings_pack::announce_to_all_tiers, true);

    NSInteger downKB = [[NSUserDefaults standardUserDefaults] integerForKey:@"dlbox.bt.downLimit"];
    NSInteger upKB = [[NSUserDefaults standardUserDefaults] integerForKey:@"dlbox.bt.upLimit"];
    if (downKB > 0) sp.set_int(lt::settings_pack::download_rate_limit, (int)(downKB * 1024));
    if (upKB > 0) sp.set_int(lt::settings_pack::upload_rate_limit, (int)(upKB * 1024));

    lt::session_params params(sp);

    try {
        _session.reset(new lt::session(std::move(params)));
    } catch (std::exception const &e) {
        [DLLog write:[NSString stringWithFormat:@"[BT] session 创建失败: %s", e.what()]];
        return;
    }

    _running = true;
    _alertThread = [[NSThread alloc] initWithTarget:self selector:@selector(alertLoop) object:nil];
    _alertThread.name = @"dlbox.bt.alerts";
    [_alertThread start];

    [self restoreSession];
    [DLLog write:[NSString stringWithFormat:@"[BT] %@ session 启动 · 下载目录 %@", [self versionString], _dlDir]];
}

- (void)dealloc {
    _running = false;
    if (_session) {
        _session->pause();
        _session.reset();
    }
}

#pragma mark - 恢复 / 保存

- (void)restoreSession {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *files = [fm contentsOfDirectoryAtPath:_btDir error:nil] ?: @[];
    int restored = 0;
    for (NSString *f in files) {
        if (![f hasSuffix:@".fastresume"]) continue;
        NSData *data = [NSData dataWithContentsOfFile:[_btDir stringByAppendingPathComponent:f]];
        if (data.length == 0) continue;
        lt::error_code ec;
        lt::span<char const> buf((char const *)data.bytes, data.length);
        lt::add_torrent_params p = lt::read_resume_data(buf, ec);
        if (ec) continue;
        p.save_path = _dlDir.UTF8String;
        p.flags = p.flags | lt::torrent_flags::paused;
        p.flags = p.flags & ~lt::torrent_flags::auto_managed;
        lt::error_code ec2;
        _session->add_torrent(p, ec2);
        if (!ec2) restored++;
    }
    if (restored) {
        [DLLog write:[NSString stringWithFormat:@"[BT] 恢复 %d 个任务（已暂停，待用户继续）", restored]];
    }
}

- (void)saveResumeForHandle:(lt::torrent_handle const &)h {
    if (!h.is_valid()) return;
    if (h.flags() & lt::torrent_flags::paused) return;   // 暂停中的直接跳过，恢复时再存
    h.save_resume_data(lt::torrent_handle::save_info_dict);
}

- (void)persistResumeAlert:(lt::save_resume_data_alert *)al {
    lt::entry e = lt::write_resume_data(al->params);
    std::vector<char> buf;
    lt::bencode(std::back_inserter(buf), e);
    NSString *name = [NSString stringWithFormat:@"%s.fastresume", HashToHex(al->handle.info_hashes().get_best()).UTF8String];
    NSString *path = [_btDir stringByAppendingPathComponent:name];
    NSData *data = [NSData dataWithBytes:buf.data() length:buf.size()];
    [data writeToFile:path atomically:YES];
}

#pragma mark - alerts 线程

- (void)alertLoop {
    while (_running) {
        @autoreleasepool {
            if (!_session) break;
            _session->wait_for_alert(lt::seconds(1));
            std::vector<lt::alert *> alerts;
            _session->pop_alerts(&alerts);
            for (lt::alert *a : alerts) {
                [self handleAlert:a];
            }
            // 每 30 秒存一次 resume data（alert 里带的是 1 秒节拍，累计计数）
            static int tick = 0;
            if (++tick >= 30) {
                tick = 0;
                for (auto const &h : _session->get_torrents()) {
                    [self saveResumeForHandle:h];
                }
                [[NSNotificationCenter defaultCenter] postNotificationName:DLBTTasksChangedNotification object:nil];
            }
        }
    }
}

- (void)handleAlert:(lt::alert *)a {
    if (!a) return;
    switch (a->type()) {
        case lt::save_resume_data_alert::alert_type: {
            [self persistResumeAlert:static_cast<lt::save_resume_data_alert *>(a)];
            break;
        }
        case lt::save_resume_data_failed_alert::alert_type: {
            auto *al = static_cast<lt::save_resume_data_failed_alert *>(a);
            [DLLog write:[NSString stringWithFormat:@"[BT] 保存 resume 失败: %s", al->message().c_str()]];
            break;
        }
        case lt::metadata_received_alert::alert_type: {
            auto *al = static_cast<lt::metadata_received_alert *>(a);
            [DLLog write:[NSString stringWithFormat:@"[BT] 元数据到达: %s", al->handle.status(lt::torrent_handle::query_name).name.c_str()]];
            [[NSNotificationCenter defaultCenter] postNotificationName:DLBTTasksChangedNotification object:nil];
            break;
        }
        case lt::torrent_finished_alert::alert_type: {
            auto *al = static_cast<lt::torrent_finished_alert *>(a);
            [DLLog write:[NSString stringWithFormat:@"[BT] 下载完成: %s", al->handle.status(lt::torrent_handle::query_name).name.c_str()]];
            [[NSNotificationCenter defaultCenter] postNotificationName:DLBTTasksChangedNotification object:nil];
            break;
        }
        case lt::torrent_error_alert::alert_type: {
            auto *al = static_cast<lt::torrent_error_alert *>(a);
            [DLLog write:[NSString stringWithFormat:@"[BT] 任务错误: %s", al->error.message().c_str()]];
            break;
        }
        case lt::file_error_alert::alert_type: {
            auto *al = static_cast<lt::file_error_alert *>(a);
            [DLLog write:[NSString stringWithFormat:@"[BT] 文件错误: %s", al->error.message().c_str()]];
            break;
        }
        default:
            break;
    }
}

#pragma mark - 添加任务

- (lt::torrent_handle)handleForHash:(NSString *)hash {
    if (!_session) return lt::torrent_handle();
    std::string want = hash.UTF8String;
    for (auto const &h : _session->get_torrents()) {
        if (HashToHex(h.info_hashes().get_best()).UTF8String == want) return h;
    }
    return lt::torrent_handle();
}

- (BOOL)addMagnet:(NSString *)uri error:(NSString **)error {
    [self start];
    if (!_session) { if (error) *error = @"BT 引擎未启动"; return NO; }
    if (uri.length < 8) { if (error) *error = @"磁力链接太短"; return NO; }
    try {
        lt::error_code ec;
        lt::add_torrent_params p = lt::parse_magnet_uri(std::string(uri.UTF8String), ec);
        if (ec) {
            if (error) *error = ErrToStr(ec);
            return NO;
        }
        p.save_path = _dlDir.UTF8String;
        p.flags = p.flags & ~lt::torrent_flags::auto_managed;
        p.flags = p.flags & ~lt::torrent_flags::paused;
        lt::error_code ec2;
        _session->add_torrent(p, ec2);
        if (ec2) { if (error) *error = ErrToStr(ec2); return NO; }
        [DLLog write:[NSString stringWithFormat:@"[BT] 添加 magnet %@", uri]];
        [[NSNotificationCenter defaultCenter] postNotificationName:DLBTTasksChangedNotification object:nil];
        return YES;
    } catch (std::exception const &e) {
        if (error) *error = [NSString stringWithFormat:@"%s", e.what()];
        return NO;
    }
}

- (BOOL)addTorrentFile:(NSString *)path error:(NSString **)error {
    [self start];
    if (!_session) { if (error) *error = @"BT 引擎未启动"; return NO; }
    try {
        lt::error_code ec;
        lt::add_torrent_params p = lt::load_torrent_file(std::string(path.UTF8String));
        if (ec) {
            if (error) *error = ErrToStr(ec);
            return NO;
        }
        p.save_path = _dlDir.UTF8String;
        p.flags = p.flags & ~lt::torrent_flags::auto_managed;
        p.flags = p.flags & ~lt::torrent_flags::paused;
        lt::error_code ec2;
        _session->add_torrent(p, ec2);
        if (ec2) { if (error) *error = ErrToStr(ec2); return NO; }
        [DLLog write:[NSString stringWithFormat:@"[BT] 添加种子文件 %@", path]];
        [[NSNotificationCenter defaultCenter] postNotificationName:DLBTTasksChangedNotification object:nil];
        return YES;
    } catch (std::exception const &e) {
        if (error) *error = [NSString stringWithFormat:@"%s", e.what()];
        return NO;
    }
}

#pragma mark - 任务列表

- (NSArray<DLBTTask *> *)tasks {
    NSMutableArray<DLBTTask *> *out = [NSMutableArray array];
    if (!_session) return out;
    for (auto const &h : _session->get_torrents()) {
        @autoreleasepool {
            lt::torrent_status st = h.status(lt::torrent_handle::query_name);
            DLBTTask *t = [[DLBTTask alloc] init];
            t.infoHash = HashToHex(h.info_hashes().get_best());
            t.name = [NSString stringWithUTF8String:st.name.c_str()];
            if (t.name.length == 0) t.name = @"获取元数据中…";
            t.progress = st.progress;
            t.totalDone = (long long)st.total_done;
            t.totalWanted = (long long)st.total_wanted;
            t.downloadRate = (double)st.download_rate;
            t.uploadRate = (double)st.upload_rate;
            t.numPeers = st.num_peers;
            t.numSeeds = st.num_seeds;

            BOOL paused = static_cast<bool>(h.flags() & lt::torrent_flags::paused);
            if (!st.errc && paused) {
                t.state = DLBTTaskStatePaused;
                t.stateText = @"已暂停";
            } else if (st.errc) {
                t.state = DLBTTaskStateError;
                t.stateText = @"错误";
                t.errorText = [NSString stringWithUTF8String:st.errc.message().c_str()];
            } else {
                switch (st.state) {
                    case lt::torrent_status::downloading_metadata:
                        t.state = DLBTTaskStateMetadata;
                        t.stateText = @"获取元数据";
                        break;
                    case lt::torrent_status::checking_files:
                    case lt::torrent_status::checking_resume_data:
                        t.state = DLBTTaskStateChecking;
                        t.stateText = @"校验中";
                        break;
                    case lt::torrent_status::downloading:
                    case lt::torrent_status::finished:
                        t.state = DLBTTaskStateDownloading;
                        t.stateText = @"下载中";
                        break;
                    case lt::torrent_status::seeding:
                        t.state = DLBTTaskStateSeeding;
                        t.stateText = @"做种中";
                        break;
                    default:
                        t.state = DLBTTaskStateDownloading;
                        t.stateText = @"运行中";
                        break;
                }
            }
            [out addObject:t];
        }
    }
    return out;
}

#pragma mark - 控制

- (void)pauseTask:(NSString *)infoHash {
    if (!_session) return;
    for (auto const &h : _session->get_torrents()) {
        if ([HashToHex(h.info_hashes().get_best()) isEqualToString:infoHash]) {
            h.pause();
            h.save_resume_data(lt::torrent_handle::save_info_dict);
            break;
        }
    }
}

- (void)resumeTask:(NSString *)infoHash {
    if (!_session) return;
    for (auto const &h : _session->get_torrents()) {
        if ([HashToHex(h.info_hashes().get_best()) isEqualToString:infoHash]) {
            h.resume();
            break;
        }
    }
}

- (void)removeTask:(NSString *)infoHash deleteFiles:(BOOL)deleteFiles {
    if (!_session) return;
    for (auto const &h : _session->get_torrents()) {
        if ([HashToHex(h.info_hashes().get_best()) isEqualToString:infoHash]) {
            _session->remove_torrent(h, deleteFiles ? lt::session::delete_files : lt::remove_flags_t{});
            NSString *fp = [_btDir stringByAppendingPathComponent:[infoHash stringByAppendingString:@".fastresume"]];
            [[NSFileManager defaultManager] removeItemAtPath:fp error:nil];
            break;
        }
    }
}

#pragma mark - 设置

- (void)setDownloadLimitKB:(NSInteger)down uploadLimitKB:(NSInteger)up {
    if (!_session) return;
    lt::settings_pack sp;
    sp.set_int(lt::settings_pack::download_rate_limit, down > 0 ? (int)(down * 1024) : 0);
    sp.set_int(lt::settings_pack::upload_rate_limit, up > 0 ? (int)(up * 1024) : 0);
    _session->apply_settings(sp);
    [[NSUserDefaults standardUserDefaults] setInteger:down forKey:@"dlbox.bt.downLimit"];
    [[NSUserDefaults standardUserDefaults] setInteger:up forKey:@"dlbox.bt.upLimit"];
}

- (void)setSeedingEnabled:(BOOL)enabled {
    if (!_session) return;
    lt::settings_pack sp;
    sp.set_int(lt::settings_pack::upload_rate_limit, enabled ? 0x7fffffff : 1);
    _session->apply_settings(sp);
}

@end
