# DLBox — iOS 原生下载器 · 架构与接口说明

> 本文档供后续每个阶段的新会话快速对齐，不要依赖聊天历史。

## 目标

无 Xcode、纯命令行交叉编译的 iOS 下载 App，产出未签名 IPA，用户自行签名安装。

- 引擎：arm64 iOS，最低 iOS 14.0
- SDK：`$SDK`（iPhoneOS16.5，含 libSystem.B.tbd / UIKit / Foundation / CommonCrypto）
- 编译器：`$CLANG`（clang 15 或更新）
- 链接器：`$LD`（ld64.lld）
- 语言：Objective-C + C，`-fobjc-arc -fblocks`

## 构建链路（已实测通过）

```sh
SDK="$HOME/theos/sdks/iPhoneOS16.5.sdk"
CLANG=clang
LD=ld64.lld

# 编译
$CLANG -target arm64-apple-ios14.0 -isysroot $SDK -fobjc-arc -O1 -c src.m -o obj.o

# 链接
$LD -arch arm64 -platform_version ios 14.0 16.5 -syslibroot $SDK \
    -e _main -o Payload/DLBox.app/DLBox obj1.o obj2.o \
    $SDK/usr/lib/libSystem.B.tbd \
    -F$SDK/System/Library/Frameworks \
    -framework UIKit -framework Foundation -framework CoreGraphics
```

要点：
- 入口是 `-e _main`，必须有 `main()`（不能靠 `@main` 或 runtime 自动入口）
- `libSystem.B.tbd` 必须显式列出
- 构建过程不需要符号链接；交叉编译产物只能在真机上运行
- IPA 打包：`zip -rq X.ipa Payload`，目录结构 `Payload/DLBox.app/`
- **Info.plist 必须含 `UILaunchScreen`（空字典即可）**：否则 iOS 会把 App 当老式应用以兼容模式（letterbox）运行，全面屏设备上下留黑边、分辨率锁旧机型尺寸

## 分期

| 期 | 内容 | 状态 |
|---|---|---|
| P0 | 骨架：能装、能显示界面的最小 App | ✅ 完成（2026-10-22，一次通过，真机验证 OK） |
| P1 | HTTP 引擎：后台会话、队列、Range 断点续传、进度持久化 | ✅ 完成（2026-10-22，真机验证通过） |
| P2 | UI：任务列表 / 添加 / 暂停续传 / 进度 / 设置 + 多段并发下载加速 | ✅ 完成（2026-10-22，真机验证通过，0.1.1 P2-fix4） |
| P3 | BT 核心：bencode、torrent、tracker、peer wire、分片、SHA1、写盘 | ✅ 已完成（2026-10-24，随 P4 落地后完整下载链路验证通过） |
| P4 | magnet + DHT + PEX + 做种 | ❌ **全面烂尾**（2026-10-24 搁置，见「P4 终止说明」） |
| P5 | 网页资源爬虫：解析网页抓取下载链接、批量入队 | 🚧 进行中（2026-10-24 启动，见「P5 方案」） |
| P6 | libtorrent 内核移植（iTorrent 同款内核）：BT 交给 libtorrent 2.0.11 | 🚧 进行中（2026-10-29，见「P6 说明」） |

> 交付约定：每个分期完成后，先在 IPA 里带上可识别的标记/验证方式（如版本号、界面标识、测试入口），让作者能一眼判断该期目标是否达成；然后把 IPA 发给作者签名装机验证，**验证通过后**才在本文档把该期标记为完成，并提醒 作者开新对话（压缩上下文、便于对齐）。
>
> **IPA 修订命名**：每次返工 / 修 bug 后重新打包，IPA 文件名用 `-fixN` 后缀递增标注（如 `DLBox-P3.ipa` → `DLBox-P3-fix1.ipa` → `DLBox-P3-fix2.ipa`），并把修订号写进版本号（`0.2.0 (P3-fix1)`）；**保留之前所有版本的 IPA，不覆盖、不删除**（参考 P2 的 `P2-fix` / `P2-fix2` / `P2-fix3` / `P2-fix4`）。

## 关键设计决定

1. **HTTP 下载用 `NSURLSession` 的 background session**：iOS 切后台继续下，这是原生方案对沙箱方案的核心优势
2. **断点续传**：`NSURLSessionDownloadTask` 自带 resume data；并发分段用 `Range` 头 + 手工拼文件
3. **BT 引擎纯 C 实现**（`bt_*.c`），UI 层 ObjC；SHA1 用 SDK 自带的 `CommonCrypto/CommonDigest.h` —— 该引擎已随 P4 烂尾冻结，BT 功能改由 iTorrent 承担
4. **做种**：peer wire 的 unchoke 上传路径 + 本地文件读取，不依赖外部库 —— 同上，冻结

## 目录约定

```
DLBox/                 仓库根（clone 下来的目录）
├── SPEC.md         本文件
├── README.md
├── build.sh        一键编译打包（1=C 2=ObjC 3=链接 4=打包）
├── src/            ObjC 源码（UI + 引擎桥接）
├── csrc/           C 源码（BT 引擎，已冻结，默认不参与编译）
├── res/Info.plist
├── tools/          GitHub Actions workflow（libtorrent 云端编译）
└── build/          Payload/ 与产物（每次全量重建）

仓库外的依赖（换机器先备齐，路径都可用环境变量覆盖）：
$LT_ROOT/                         libtorrent 2.0.11 + OpenSSL 3.0.15（默认 $HOME/dlbox-deps/prebuilt）
$BOOST_ROOT/                      Boost 头文件（默认 $HOME/dlbox-deps/boost）
$SDK                              iOS SDK（默认 $HOME/theos/sdks/iPhoneOS16.5.sdk）
$IPA_DIR/                         构建产物（默认 仓库下 out/）
```

## P1 落地说明（2026-10-22）

新增源文件（均在 `src/`，被 build.sh 的 `src/*.m` 通配自动收编）：

| 文件 | 职责 |
|---|---|
| `DLTask.h/.m` | 任务模型：id/url/文件名/状态机/字节数/进度，含 plist 序列化 |
| `DLTaskStore.h/.m` | 持久化：`Documents/dlbox/tasks.plist` 队列 + `.resume` 断点文件 + `downloads/` 完成目录 |
| `DLDownloadEngine.h/.m` | 引擎单例：background session、并发调度、委托、resume data 断点续传 |

关键实现点：

- **后台会话**：`backgroundSessionConfigurationWithIdentifier:`，`sessionSendsLaunchEvents=YES`，identifier 固定 `dev.dlbox.app.background`；`AppDelegate` 已接 `handleEventsForBackgroundURLSession:` 并持有 completionHandler，在 `URLSessionDidFinishEventsForBackgroundURLSession:` 里释放。
- **断点续传**：暂停走 `cancelByProducingResumeData:`，resume data 存 `<taskId>.resume`；恢复走 `downloadTaskWithResumeData:`。resume data 里的 `NSURLSessionResumeBytesReceived` 用于回填进度。
- **队列恢复**：启动时 `getTasksWithCompletionHandler:` 用 `taskDescription`（= taskId）把系统还回来的 downloadTask 与 DLTask 重新绑定；标记 running 但没还回来的任务降级为 waiting 重排。
- **进度持久化**：`didWriteData:` 节流 0.5s 写 plist；完成/失败/暂停立即写。
- **通知**：`DLDownloadTasksChangedNotification`（增删/状态变化）、`DLDownloadProgressNotification`（进度），UI 监听后整表刷新。

已知局限（后续期处理）：

1. **App 被用户上滑杀掉后，Running 任务会从头重下**——downloadTask 的断点只在「主动暂停」或「系统在后台续跑」时可靠；要跨进程真断点，需在前台 session 用 dataTask + `Range` 头手工落盘拼文件（见下）。
2. **并发多段（Range 分段拼文件）未在 P1 实现**：background session 下 dataTask 在 App 挂起后不可靠，多连接加速是前台特性，归入 P2 用 foreground session 补。
3. 未做 HTTPS 证书校验自定义、限速、任务排序；UI 仅最小验证用（列表 + 添加 + 点按暂停/恢复 + 左滑删除）。

完成文件落盘目录：`Documents/dlbox/downloads/`（重名自动加 ` (n)`）。ATS 已在 Info.plist 放开任意加载（方便 http 直链测试）。

## P2 落地说明（2026-10-22）

范围：正式 UI + 多段并发下载加速（真机验证通过，0.1.1 P2-fix4）。

新增源文件（`src/`，均被 build.sh 通配自动收编）：

| 文件 | 职责 |
|---|---|
| `DLSettings.h/.m` | NSUserDefaults 设置：并发数 / 分段数 / 限速 / 允许 HTTP / 下载模式 |
| `DLRateLimiter.h/.m` | 全局令牌桶限速器（仅 foreground 分段 dataTask 生效） |
| `DLSegmentDownloader.h/.m` | 单任务多段下载：分 N 段 dataTask + Range 写 part-N，拼到 `.tmp-<taskId>`，完成回调引擎重命名落盘 |
| `DLListViewController.h/.m` | 任务列表（自定义 cell：进度条 / 字节 / 速度 / 段数 / 暂停恢复按钮） |
| `DLTaskCell.h/.m` | 任务 cell |
| `DLAddViewController.h/.m` | 添加任务：URL 校验、剪贴板自动填充、HTTP 开关校验 |
| `DLSettingsViewController.h/.m` | 设置页：并发 / 分段 / 限速 / 模式 / HTTP / 目录 / 清空 / 说明 / 版本 |
| `DLFilesViewController.h/.m` | 下载目录：文件列表 / 分享 / 删除 |

改动：`DLTask` 增 mode / segmentCount / supportsRange / probed / segments / speed；`DLTaskStore` 增 parts 目录；`DLDownloadEngine` 双 session（background 整段 + foreground 分段）、Range 探测、段完成拼装、失败保留分段续传；`AppDelegate` 改 TabBar；`RootViewController` 已删除。

关键实现：

- **分段流程**：GET `Range: bytes=0-0` 探测 → 206 支持 Range（解析 Content-Range 总大小）→ 分 N 段（默认 4，<1MB 单段）→ 每段 dataTask 写 `part-N` → 全完成拼到 `.tmp-<taskId>` → 引擎 `uniquePathFor` 重命名到 `downloads/`。
- **断点续传**：暂停取消全部段并 `syncToTask`（每段 start/end/done 落 plist）；恢复以 part 文件实际大小为准续传 Range。
- **限速**：令牌桶，`consume` 在后台串行 delegate 队列上阻塞（usleep），TCP 流控自然降速；仅 foreground 分段生效。
- **后台模式**：保留 P1 background downloadTask（resume data），设置里可切「后台整段」。

验证点（真机一眼判断 P2 达成）：

- 设置页底部「版本 0.1.0 (P2)」；
- 下载中 cell 显示「N 段」+ 实时速度；
- 设置页有并发 / 分段 / 限速 / 模式等项，改分段数、限速即时生效；
- 下载完成文件出现在「设置 → 下载目录」，可点按分享。

已知局限：

1. 多段加速依赖前台，App 被系统挂起后暂停，回前台自动续传（分段进度已持久化）。
2. 限速仅对「分段加速」模式生效；后台整段不受限速。
3. 同名任务靠 `.tmp-<taskId>` 中转 + 落盘时 `uniquePathFor` 规避冲突。

## P2 真机反馈与返工记录（2026-10-22，已全部修复，真机验证通过）

首版真机反馈 3 个问题，均已修复：

1. **添加页键盘**：遮挡 / 无法收起 / 键盘丑 → 全屏 modal + `UIScrollView` 键盘避让 + 点空白/拖动/return 收起 + 全局深色（键盘同步变深色）。
2. **UI 未利用全屏 + 分辨率不搭**：根因是 Info.plist 缺 `UILaunchScreen`，iOS 以兼容模式（letterbox）运行，上下黑边、分辨率锁旧机型 → 加 `UILaunchScreen` 空字典修复，App 按原生分辨率整屏渲染。
3. **爬虫功能漏记**（非 bug）→ 补入 P5（见下）。

返工链路：`P2-fix` → `P2-fix4`，最终 `0.1.1 (P2-fix4)` 真机验证通过。

## P3 落地说明（已完成，2026-10-24）

范围：BT 核心引擎，纯 C 实现（`csrc/bt_*.c`），UI 桥接 `DLBTSession` + `DLBTViewController`（底部新增「BT」Tab）。

新增 C 源文件（`csrc/`，build.sh 已收编并链接）：

| 文件 | 职责 |
|---|---|
| `bt_common.c` | 字节缓冲 / hex / 随机 / peer_id |
| `bt_bencode.c` | bencode 编解码（记录 info 字典原始字节区间） |
| `bt_torrent.c` | torrent 解析：info hash（对原始 info 字典 SHA1）、单/多文件、announce-list 展开去重 |
| `bt_sha1.c` | SHA1（CommonCrypto） |
| `bt_tracker.c` | HTTP tracker announce（compact 响应） |
| `bt_peer.c` | peer wire：握手 + 全消息类型 + 16KB block pipelining |
| `bt_storage.c` | 稀疏预分配 + 跨文件 piece 落盘 |
| `bt_engine.c` | select 事件循环、piece 调度、超时重发、重 announce、校验落盘 |

新增 ObjC 文件（`src/`）：`DLBTSession`（引擎线程封装 + 通知）、`DLBTViewController`（BT 页）。`AppDelegate` 加第三个 Tab。

关键实现：

- 下载策略：顺序选 piece，一次下载一个 piece，多 peer 并行请求该 piece 的 16KB block（每 peer 最多 24 个在途）；piece 收齐后 SHA1 校验 → 跨文件落盘 → 广播 have → 下一 piece。
- tracker：HTTP + HTTPS（内置 http 裸 socket；https / 外置经 ObjC `NSURLSession` 回调，解析复用 C 的 `bt_tracker_parse_response`；UDP tracker / magnet / DHT / PEX / 做种 归 P4）；活跃 peer 少于 3 个且超 30 秒时重新 announce。
- 校验失败重下该 piece；block 30 秒超时重发；180 秒无数据判失败。

验证点（真机一眼判断）：底部「BT」Tab + 标题「BT 下载 · P3」+ 设置页版本 `0.2.0 (P3-fixN)`；粘贴 .torrent 链接 → 开始 → 日志依次打印种子摘要 / tracker peer 数 / 连接 / piece 落盘。

返工记录：

- `P3-fix1`：修复单文件写盘路径 bug（原把文件路径拼成目录导致 open 失败）+ 失败错误信息乱码（`%s` → UTF-8）。
- `P3-fix2`：支持 https tracker —— Debian 官方 tracker（http）已停摆返回 0 peer，现代 tracker 基本都是 https；引擎新增外部 announce 回调，ObjC 层用 `NSURLSession` 请求（http/https 通吃），解析复用 C 侧。
- `P3-fix3`：修复 0 字节下载 —— 部分 tracker（如 torrent.ubuntu.com）只返回极少数 IPv4 peer，且该 peer 不发 bitfield；原逻辑「收到 bitfield 才发 request」导致永不请求，改为**无 bitfield 时乐观请求**（有超时兜底）。
- 本地已用 Python 参考实现对比验证 bencode / torrent / info hash / 跨文件写盘 / tracker 响应解析，结果一致；网络部分（tracker / peer wire）只能在真机验证。

已知局限（P3 阶段，均已由 P4 解决）：

1. 只解析 compact IPv4 `peers`；未解析 `peers6`（IPv6）与非 compact 字典格式 peer 列表——部分 tracker（如 Ubuntu）IPv4 做种者极少，导致可连 peer 很少。（P4-fix2 已支持 peers6 / 非 compact / IPv6）
2. 依赖 tracker 提供 peer；无 DHT，tracker 失效/源少时无法自行发现 peer。（P4 已加 DHT）

### 完成状态（2026-10-24）

- P3 代码全部落地并通过本地对照验证（bencode / torrent / info hash / 跨文件写盘 / tracker 响应解析，均与 Python 参考实现一致）。
- P3 阶段的真机问题（下载 0 字节）已由 P4 解决：DHT 上线后不再依赖 tracker 单一源，下载链路完整跑通。
- ✅ P3 阶段任务已完成。

## P4 落地说明（2026-10-24，已搁置）

范围：magnet 链接 + DHT（BEP-5）+ PEX（BEP-11）+ 做种。

新增 C 源文件（`csrc/`，build.sh 已收编）：

| 文件 | 职责 |
|---|---|
| `bt_dht.c` | Kademlia DHT 客户端：UDP 查询（ping/find_node/get_peers/announce_peer）、简化路由表、bootstrap、compact nodes 解析、XOR 距离 |
| `bt_magnet.c` | magnet 链接解析（`xt=urn:btih:` 40-hex / 32-base32、`dn`、`tr` 去重） |

改动：

- `bt_bencode` 增 `bt_be_clone`（深拷贝）与 `bt_be_decode_prefix`（返回消费字节数，用于解析「bencode 字典 + 原始数据」拼接的 ut_metadata data 消息）。
- `bt_peer` 增扩展协议（BEP-10）：握手 reserved 位、extended 消息收发、扩展握手、入站连接（对方先发握手）、request 消息回调（做种响应）。
- `bt_engine` 大改：metadata 下载状态机、DHT 集成、known-peers 池、PEX 定期交换、做种（监听 + 入站 + 响应 request + 上传计数）、下载完成自动转做种。
- `bt_storage` 增 `open_read`（不 truncate，做种检测）、`read_range`（跨文件读）、`is_complete`；open 改为 O_RDWR（读写兼用）。
- ObjC：`DLBTSession` 增 `startWithMagnet:` 与 `seeding` 状态；`DLBTViewController` 支持 magnet 输入、做种/获取元数据状态显示。

关键流程：

- **magnet**：解析 → 仅 info_hash + name + trackers → DHT/tracker 找 peer → 扩展握手 → ut_metadata 逐片下载 metadata（先 piece 0 拿 total_size）→ SHA1(metadata) == info_hash 校验 → 包装成完整 torrent → 走正常下载。
- **DHT**：node id 随机，端口与 TCP 一致（6881）；bootstrap 用 router.bittorrent.com / router.utorrent.com / dht.transmissionbt.com / router.bitcomet.com；get_peers 拿 peers + token，announce_peer 宣告自己（做种/下载中）。
- **PEX**：本地 ut_metadata id=1、ut_pex id=2；每 60s 向支持 ut_pex 的 peer 交换 known peers（added + added.f）。
- **做种**：下载完成自动转做种（监听 6881 + 广播 bitfield + unchoke + 响应 request）；重新打开已完成种子/magnet 时，检测文件完整则直接进做种。

版本与验证点（真机一眼判断 P4 达成）：

- 设置页版本 `0.3.0 (P4)`；BT 页标题「BT 下载 · P4」。
- 粘贴 magnet 链接 → 日志依次出现「magnet 链接 · info_hash …」「开始下载 metadata」「metadata 总大小 …」「metadata 下载完成」→ 之后正常下载 → 完成日志「下载完成，转入做种模式」。
- 下载完成/重新打开已完成种子后，状态栏显示「做种中…」，详情显示上传速度。
- 日志可见 `[DHT] DHT bootstrap 完成…`、`[DHT] DHT 查询 info_hash 得到 N 个 peer`。

已知局限（P4 阶段）：

1. DHT 只解析 IPv4 compact peers/nodes（BEP-5），未处理 IPv6。
2. DHT 路由表为简化实现（固定 256 槽位，按 last_seen 淘汰），未做完整 Kademlia k-bucket 与入站 query 响应；announce 依赖 get_peers 返回的 token，若网络环境 NAT 严格，入站做种可能连不上（需公网可达或 UPnP，未实现）。
3. metadata 下载依赖对端支持 ut_metadata（BEP-9）；极端旧客户端不支持则 magnet 无解，需回退 tracker 下 .torrent。
4. 做种不限制上传速率、无独立 choke 策略（一律 unchoke），适合个人小规模分享。
5. 断点续传（跨进程恢复 have 位图）仍未实现：下载到一半杀 App 重开会从零下载（除非文件已完整才会直接做种）。

返工记录：

- `P4-fix1`：修复 magnet 元数据下载卡死——根因是 `bt_dht_create` 被放在了 `metadata_download` 之后，导致拿元数据阶段 `e->dht` 恒为 NULL，全程只靠 tracker 找 peer（Ubuntu tracker 仅返回 1 个不支持 ut_metadata 的 Canonical 做种端）。修复：DHT 创建提前到 metadata 下载之前；同时补充 bootstrap 节点（dht.libtorrent.org:25401、router.silotis.us:6881），并让 metadata 阶段不再发 interested（消除「对方解除限流」误导日志）。
- `P4-fix2`：修复 tracker 返回 0 个 peer——真机日志显示 tracker 每次都 0 peer，抓包确认 **Ubuntu 的 tracker 返回的是「非 compact 字典列表」格式的 peers，且几乎全是 IPv6 地址**（`2409:…`/`2408:…`/`2001:…`），原解析只认 compact IPv4 字符串。修复：`bt_tracker` 支持非 compact 字典格式 peers 与 `peers6`（compact IPv6）、用 `inet_pton` 解析点分/冒号 IP；`bt_peer` 支持 IPv6 socket（AF_INET6）；`bt_peer_addr` 结构扩展为 16 字节 ip + `is_ipv6` 标志（引擎/去重/日志/PEX 全部适配）；BT 页新增「复制日志」按钮方便回传日志；DHT 加 bootstrap 逐节点诊断日志（区分域名解析失败 / 无响应超时）。
- `P4-fix3`：修复下载慢/「断联」——真机日志显示 metadata 全通、piece 已落盘，但同一个 peer 地址被反复重复连接，30 个槽位被重复节点占满、真做种者挤不进来。修复：`connect_from_known` 连接前按地址去重（跳过已有活跃连接的 peer）；连接上限 30→50；block 分配改为轮询分散（每 peer 每轮最多 1 个 block，避免先遍历到的「假做种」CDN 节点独占全部 block 卡超时）；block 请求超时 30s→15s；metadata 阶段抑制无意义的「收到 bitfield 0/0 片」日志。
- `P4-fix4`：修复「元数据下完进度条直接满、直接进做种」——根因是下载模式用 `ftruncate` 预分配了 4.4GB 空洞文件，重开时 `is_complete` 只看文件大小（== 完整大小）就误判已完整。修复：引入**完成标记文件**（`save_dir/.dlbox-<info_hash>.complete`），下载完成时写入，完整性判定改为「文件大小匹配 && 标记存在」；同时做日志降噪（删 `unchoke` 刷屏日志、「发起 N 连接」只在 N≥5 时打印、做种时只 announce + 监听入站不再主动连 50 个做种者）；「复制日志」按钮从 BT 页移除，改到**设置页 → BT → 导出 BT 日志**（写 `bt-log.txt` + 复制剪贴板 + 系统分享面板）。
- `P4-fix5`：修复「下载慢到爆」——根因是 P3 遗留的**顺序下载架构**：一次只下一个 piece（256KB），50 个 peer 抢同一个 piece 的 16 个 block，绝大多数 peer 闲置、慢节点超时拖累整体。改为**多 piece 并行下载**（`BT_MAX_ACTIVE_PIECES=12`：同时 12 个 piece、各自独立缓冲与 block 状态，请求分配跨 piece 轮询，最大程度打满多 peer 带宽）。同时：状态栏直接显示实时速度（「下载中 · 1.2 MB/s」），进度改用已接收字节（更平滑）；日志进一步降噪（删「已连接 peer / 收到 bitfield / peer 支持扩展协议」逐条输出），日志上限 6 万字符、UI 刷新节流 0.15s 防止跳动。
- `P4-fix6`：继续优化速度——50 个 peer 里混入大量「假做种」节点（发 bitfield 声称有全量数据、却长时间不给字节，Ubuntu CDN / 限速 IPv6 节点尤多），占满 50 槽位挤走真做种者。修复：**死 peer 淘汰 + 黑名单**（连上 30s 一个字节没给 → 断开拉黑 10 分钟；曾给过数据但 90s 静默 → 同样淘汰），腾出槽位连新 peer。同时状态栏增加**进度百分比（0.01% 精度）+ 预计剩余时间（ETA）**。

- `P4-fix7`：修复「magnet 元数据完全下不来」+ 大幅扩 peer 来源。真机日志显示 tracker 每次只回 1 个 peer、DHT 前几轮查询 0 peer，随后 DHT 才挖到 389 个；而 **metadata 派发逻辑有致命缺陷**：`meta_piece0_pending` 让 piece 0 只派给唯一一个 peer 且**超时后永不复位**，一旦那个 peer 是假做种（Ubuntu CDN/IPv6 限流节点极多）整盘卡死 5 分钟，一片都拿不到；同时不解析扩展握手里的 `metadata_size`，只能干等 piece 0 才知道总长。修复分五块：
  1. **metadata 派发重写**：解析 BEP-10 扩展握手的 `metadata_size`（libtorrent / Transmission / qBittorrent 都会带）→ 立刻知道总长，全部分片并行拉；每片最多 2 个副本、每 peer 一次 1 片、**8 秒无响应即释放重派**；大小未知时允许多达 3 个 peer 并发要 piece 0。
  2. **连接上限 50 → 150**，并在引擎启动时 `setrlimit(RLIMIT_NOFILE, 1024)`（iOS 默认软限制 256，否则大批连接 EBADF）；known 池 256 → 1024，`connect_from_known` 改**环形遍历游标**（原先每次都从 0 号开始，反复试同一批死地址）。
  3. **多源扩 peer**：tracker announce 参数补 `no_peer_id=1`、`numwant` 80 → 200；DHT 路由表容量 256 → 512；**tracker 返回的 IPv4 peer 直接当 DHT 入口节点**（`bt_dht_add_node`，优先级高于公共 bootstrap，绕开国内被墙的 6 个公共节点）；metadata 阶段每 10 秒持续 `get_peers`（旧逻辑只在 peer<8 时补一次），并把 PEX 交换提前到 metadata 阶段（每 30 秒）。
  4. **做种时能供 metadata**：`bt_torrent` 保存 info 字典原始字节（`info_raw`），扩展握手里声明 `metadata_size`，收到 `msg_type=0` 请求就回 `msg_type=1` + 原始字节 —— 别的 magnet 客户端可以直接从本机拉元数据。
  5. **可观测性**：新增日志「连接上限 150，进程 fd 限制 N」、metadata 阶段每 4 秒一行「metadata 进度 x/y 片 · 可提供源 n 个 · 活跃 peer m」或「metadata 等待元数据大小 · 可提供源 n · 活跃 peer m · 已知 peer k」，BT 页标题 `BT 下载 · P4-fix7`。
  - 注：DHT `get_peers` 是阻塞实现（内部 select 等 UDP），timeout 已压到 2–3 秒，避免长时间卡住下载主循环。

- `P4-fix8`：修「速度上不去、过不了 1MB/s」。fix7 之后元数据 20 秒内到位、150 连接、tracker 给 50 个 peer，但吞吐仍是几百 KB。根因是**块请求的总量太小 + 被僵尸稀释**：全局只有 `BT_MAX_ACTIVE_PIECES=12` 片 × 16 块 = **192 个在途块**，150 个 peer 平均每人 1.28 块，等于串行请求，吞吐被跨国 RTT 锁死；而这些块又有一半被「假做种」领走，要等 15 秒超时才回收。修复：
  1. **并行窗口 12 片 → 48 片**（在途块 192 → 768；缓冲约 12MB，分配失败时安静降级不崩）。
  2. **分级管道**：给过数据的 peer 灌满 24 块（`BT_PIPELINE_TRUSTED`），新 peer 只给 2 块试探（`BT_PIPELINE_NEW`），给过数据但最近 5 秒静默的降到 4 块。僵尸再也吃不到大片额度。
  3. **块超时 15s → 8s**，僵尸领走的块尽快回收；僵尸淘汰阈值 30s → 15s（零数据）/ 90s → 60s（静默）。
  4. **跨片轮转游标**（`assign_cursor`）：块从不同 active piece 里取，避免所有 peer 挤同一片。
  5. **IPv4 优先连接**：`connect_from_known` 改两趟（先 IPv4 占满槽位，IPv6 只做补充），因为海外 IPv6 假做种比例高。
  6. **下载阶段 DHT 不再停摆**：原先活跃 peer ≥100 就完全不查 DHT，死 peer 淘汰后没有新血；改为每 45 秒无条件 `get_peers`（timeout 2s）。
  7. select 轮询 500ms → 250ms；日志由「每片一条」改「每 50 片一条 + 10 秒摘要」：`进度 x/y 片（z%）· X.XX MB/s · 活跃 n（有效 m）· 在途块 k · 已知 p`（「有效」= 给过数据的 peer 数，是判断 swarm 质量的关键指标）。

- `P4-fix9`：修「下载到一半闪退」，并新增持久化诊断日志。**闪退根因基本锁定 SIGPIPE**：引擎里所有 TCP socket（peer 连接 / 入站 accept / listen / tracker）都没设 `SO_NOSIGPIPE`，也没有 `signal(SIGPIPE, SIG_IGN)`。Darwin 上往已被 RST 的连接 `send()` 会触发 SIGPIPE，默认动作是**直接终止进程**——连崩溃日志都来不及写。fix8 把连接提到 150、每 peer 管道 24 块，往死连接写的概率暴涨，正好对上「下一半闪退」。修复：新增 `bt_set_nosigpipe(fd)`（`bt_common.c`），在 `bt_peer_connect` / `bt_peer_accept` / `start_listen` / tracker socket 四处调用；同时在 `DLLog setup` 里全局 `signal(SIGPIPE, SIG_IGN)` 兜底。
  同时按 作者要求补**应用日志**（`src/DLLog.h/.m`）：
  1. 日志落盘 `Documents/dlbox/logs/dlbox.log`，每行带毫秒时间戳，`write()` 直写不经缓冲，1MB 上限自动滚动（`.old`）。
  2. 崩溃捕获：`NSSetUncaughtExceptionHandler` + SIGSEGV/SIGABRT/SIGBUS/SIGILL/SIGFPE 信号处理器（async-signal-safe 写入）。
  3. 异常退出检测：启动写 `running.flag`，正常退出删除；下次启动发现残留就记一行「上次运行未正常结束」。
  4. 每 15 秒一行内存心跳（`task_info` 的 `phys_footprint`）+ 内存警告/进后台事件——被系统 OOM 杀掉（SIGKILL）时没有崩溃记录，但能看心跳曲线判断是不是内存打爆。
  5. 设置页 → BT → **诊断日志**：导出（剪贴板 + 系统分享）/ 显示当前内存占用。
  - 注：含中文的 `@"..."` 字面量在 Mach-O 里是 UTF-16LE，用 `grep -a` 搜不到，核验要用字节匹配或 `tr -d '\000'`。

- `P4-fix10`：修「日志显示 2–3MB/s，实际不到 1MB/s」。作者的诊断日志给了决定性数据：18:51:15 到 18:53:22 共 127 秒、片数 53→238（185 片 × 256KB ≈ 47MB），**真实净速 0.37MB/s**，而同期日志报 9.72→3.33MB/s —— **虚高 10–25 倍**。根因是吞吐统计把「重复收到的块」也计入：块超时后原地重派给别的 peer、但从不发 `cancel`，原 peer 迟到的回包被重复累加，同时白吃带宽。修复：
  1. **`filled[]` 与 `blocks[]` 分离**：`blocks` 只表示「谁在请求」，`filled` 表示「数据确已到手」；只有第一次填充才计入 `downloaded`，速度/进度数字从此是真实值。
  2. **块超时分级 8s → 20s（已验证 peer）/ 10s（新 peer）**：8s 对跨国 IPv6 太激进，重发风暴把带宽全浪费在重复块上。
  3. **超时先发 `cancel`**，抑制原 peer 的迟到回包。
  4. 新 peer 试探额度 2 → **1 块**；僵尸淘汰 15s → 20s（减少连接风暴）。
  5. **连接节流**：`connect_from_known` 每轮最多补 20 条（日志里曾有「一次发起 54 个新连接」的风暴）；connect 失败立即进黑名单，不再反复试不可达地址。
  6. **块分配加 `hint` 扫描位**：原来每个 peer 每次找空块都线性扫 48×16，150 peer × 24 管道 ≈ 每秒千万级无效比较，纯烧 CPU。
  7. 片完成判定改用 `filled` 全满（不再要求「无在途请求」，否则重复请求会让整片永远等不齐）。

- `P4-fix12`：修「速度虚标仍在」「周期性卡顿 1–2 秒」「吞吐上不去」。Debian 种子日志给出的线索：速度显示 4.45 MB/s 但 0 片落盘；摘要节拍明显被拉长；真实速率约 0.5 MB/s。三处硬伤：
  1. **速度统计少了一个除法**：`spd = downloaded - summary_bytes` 是「这窗口的字节数」，却被直接当 MB/s 打印；窗口被阻塞拉长到 20–30 秒时就虚高 2–3 倍。且 `downloaded` 仍会被重复块污染。改为 **`(bytes_written - summary_bytes) / 实际秒数`**（只认真实落盘），状态栏 1 秒速度同步改。
  2. **卡顿根因**：`bt_dht_get_peers` 内部是阻塞 select（2 秒），跑在主循环里，期间不处理任何 socket——正好对上「卡 1–2 秒、日志无输出」。改为**独立 pthread 每 8 秒查询**，结果放互斥队列，主循环用 `drain_dht_queue` 零阻塞取用；线程只读 `fetch_hash` 副本，避免与 `metadata_to_torrent` 替换 `e->tor` 竞争；`bt_engine_stop` 同时置线程退出标志，destroy 不干等。
  3. **吞吐天花板**：`bt_peer_read` 每次事件只 `recv` 一次（16KB），40 个 peer 的上限就被「轮数 × 16KB」锁死 → 改为**循环读到 EAGAIN（单次最多 8×32KB）**；`bt_peer_flush` 同样循环写到 EAGAIN。
  4. **IPv6 限流**：海外 IPv6 假做种多、链路差，最多占 40 条连接，槽位留给 IPv4。

- `P4-fix13`：修「速度显示 0」+「在途 448 块却 0 片落盘」。两个都是我 fix12 引入/暴露的：
  1. **速度显示 0**：fix12 把速度改成只统计 `bytes_written`（真正落盘），而一旦没有任何片完成，`bytes_written` 恒为 0 → 速度永远是 0。改回 `downloaded`（首次填充的有效字节，已不受重复污染）**除以真实秒数**。
  2. **0 片落盘**：在途 448 块但 48 片缓冲无一完成，说明每片都差一两块；块超时 20 秒太长，那几块在「bitfield 声称有片、实际不给」的 peer 之间反复踢皮球。修复：超时 20s→**10s（已验证）/ 6s（新 peer）**，并引入 **endgame 模式**：某片剩余未填充块 ≤2 时，允许同一块同时向 2 个 peer 各要一份（`dup[b]` 计数），谁先到算谁的。
  3. **诊断增强**：摘要行加「缓冲 N 片缺 M 块」——直接看片为什么凑不齐（缺块多=收不到数据，缺块少=卡在个别块）。

## P4 终止说明（2026-10-24，全面烂尾，作者已宣布）

**结论：自研 BT 引擎冻结，P4 不再推进。**

一句话版本（原话记录）：*「啥子大肥鱼吃了我 20 块后搞了托大的，于是被搁置。」*

展开说：

- `P4-fix1` 到 `P4-fix13`，十三轮返工。最后一版（`0.3.0 (P4-fix13)`）仍未达到 作者的验收线：稳定 >1 MB/s、不卡顿 1–2 秒、速度不虚标。实测 Debian 种子真实净速约 0.5 MB/s，Ubuntu 更差。
- 每轮验证都要「打包 → 作者签名 → 装机 → 试 → 贴日志」，反馈周期以小时计，问题又是长尾的协议/网络质量问题（假做种、IPv6 限流、tracker 池子小），越修越像在给 libtorrent 补历史课。
- 这一期的验证成本是全程最高的，性价比明显偏低。
- **替代方案已落地**：改用现成开源客户端 **iTorrent**（[XITRIX/iTorrent](https://github.com/XITRIX/iTorrent)，内核就是 libtorrent）。官方 Release 直接提供未加密 IPA（`cryptid = 0`，arm64，iOS 16+，含简体中文，magnet / DHT / PEX / 做种 / 后台下载 / 顺序下载齐全），从官方 Release 取 `iTorrent-2.2.0.ipa`（如需要可另存 `iTorrent-2.1.1.ipa` 备用），作者自行重签安装。BT 这块以后归 iTorrent，不再归 DLBox。

**仓库处置：**

- `csrc/bt_*.c`、`src/DLBTSession*`、`src/DLBTViewController*` **原样保留、不再修 bug、不再加功能**，作为「自研协议栈到此一游」的存档。**文件不删**（作者说以后可能会自己解决），只是从构建里摘出去。
- **默认不再把 BT 编进 IPA**：`build.sh` 新增 `WITH_BT` 开关，默认 `0`——跳过 `csrc/bt_*.c`（10 个文件）、`DLBTSession.m`、`DLBTViewController.m`，同时不挂底部「BT」Tab、设置页也只剩「诊断日志」。
  - 想重新编进来：`WITH_BT=1 sh build.sh P5`。
  - ObjC 侧全部用 `#if DLBOX_WITH_BT` 包好，开关是编译期常量，没有运行时代价。
  - 效果：可执行文件从含 BT 的约 1MB 级降到 **272 KB**，链接 1.8 秒完成；C 侧 10 个文件直接不编。
- 以后 DLBox 只在 **HTTP / 网页抓取** 方向迭代（P5 起），BT 相关需求一律引导到 iTorrent。

**构建脚本用法（2026-10-24 起）：**

```sh
sh build.sh P5        # 全流程：编 C → 编 ObjC → 链接 → 打包
sh build.sh P5 1      # 只编 C（快，先跑，失败得早）
sh build.sh P5 2      # 只编 ObjC（并发 4）
sh build.sh P5 3      # 只链接
sh build.sh P5 4      # 只写 plist + 打包
WITH_BT=1 sh build.sh P5   # 把冻结的 BT 引擎也编进去
```

分步参数是为了配合「构建输出分段返回」的要求：四段各自出结果，失败当场停。**C 在 ObjC 前面**：C 侧几百毫秒就编完，先跑能最快暴露问题；ObjC 侧每个文件要十几秒，放最后。

**教训（写给以后的自己）：**

1. 协议栈类需求不要从零手写。libtorrent 十几年的工程积累、几千个 corner case，不是一个上下文能追平的；能用现成库就用现成库。
2. 当验证只能靠用户真机、每轮成本以小时和钱计的时候，先确认「这件事值不值得自研」，再动手。
3. 速度统计这种「可观测性」必须先做可信，否则会拿假数字去优化真瓶颈——P4 有一半的返工是在修自己的度量。

## P5 方案（2026-10-24 启动）

**定位**：P4 烂尾后 DLBox 收敛为「HTTP 下载 + 网页资源抓取」工具，BT 交给 iTorrent。P5 只做抓取 + 批量入队，不碰协议栈。

原始需求（用户在第一版需求里提出过「爬虫功能」，此前漏记，现补入 P5）：

- **网页链接抓取**：输入网页 URL，抓取 HTML，解析 `a[href]` / `img[src]` / `video[src]` / `audio[src]` 等，列出可下载资源，勾选批量入队。
- **过滤规则**：按扩展名 / 关键字 / 正则筛选；可选「只抓当前域名」或「跨域」。
- **请求头透传**：跟随页面的 Cookie / Referer，避免盗链拦截。
- **实现约束**：纯 ObjC + SDK 内置，不引入第三方库；以静态 HTML 为主，不做 JS 渲染。

### v1 落地清单（建议稿）

| 模块 | 内容 |
|---|---|
| `DLCrawler.h/.m` | 抓页面（`NSURLSession` dataTask，UA 用桌面 Safari、超时 20s、页面上限 5MB、UTF-8/GBK 自动识别）；正则提取链接；相对路径补全；去重；按扩展名分类；解析 0 条时自动回退 WebView |
| `DLWebRenderer.h/.m` | 兜底渲染器：隐藏 `WKWebView` 加载页面，`didFinish` 后取 `document.documentElement.outerHTML`，20s 超时，用完即弃 |
| `DLCrawlerResult` | 单条结果：绝对 URL、显示名、扩展名、分类（视频/音频/图片/压缩包/文档/种子/磁力/其他）、来源页、是否跨域 |
| `DLCrawlViewController.h/.m` | 新 Tab「抓取」：URL 输入 + 选项区（同域开关 / 扩展名白名单 / 关键字 / 正则 / 是否含图片）+ 抓取按钮 + 结果列表（多选、全选、反选）+ 底部「入队 N 条」 |
| 入队 | 复用 P2 的 `DLDownloadEngine`，批量建 `DLTask`（waiting），文件名从 URL 末段或 `Content-Disposition` 推 |
| 种子/磁力 | 单独分组展示，点击复制到剪贴板，或调 `magnet:` / `itms-services` 交给 iTorrent（iTorrent 已注册 `magnet:` scheme） |

### 验收点（真机一眼判断 P5 达成）

- 设置页版本 `0.4.0 (P5)`，底部第 4 个 Tab「抓取」。
- 输入一个静态资源页 → 显示「找到 N 个链接 · 可下载 M 个」，列表带分类标签。
- 勾选若干条 → 点「入队」→ 自动跳回任务列表，出现对应 waiting/下载中任务。
- 过滤：填 `mp4` 只剩视频，填关键字能命中文件名。

### 风险

- 交叉编译环境没有真实网络栈，**抓取逻辑无法本地联调**，只能用本地构造的 HTML 样本验证解析（把样本写进单元测试式的自检入口），真机再验网络。
- 很多资源站靠 JS 渲染 / Cloudflare 校验，静态 HTML 抓不到——这是 v1 的已知边界，不承诺。

### 已确认（2026-10-24，作者选择）

1. **抓取对象：通用网页**——任意站点，按扩展名 / 关键字 / 正则筛，不做站点专属规则。
2. **页面渲染：静态 HTML 优先，抓失败自动回退 WKWebView**——先 `NSURLSession` 取源码解析；HTTP 失败、正文为空或解析 0 条时，用隐藏 `WKWebView` 渲染后取 `document.documentElement.outerHTML` 再解析一遍。
3. **magnet / .torrent：本轮搁置**——P5 只处理 HTTP 直链。作者的计划是以后把 **libtorrent 内核**移植进 DLBox，到那时再统一接磁力/种子，不再碰自研的那套。

### 待 作者确认的旧问题（已作废，留档）

- ~~抓取对象是通用网页还是固定站点？~~ → 通用
- ~~要不要内置浏览器？~~ → 要，作为静态抓取的兜底
- ~~magnet / .torrent 怎么处理？~~ → 搁置，等 libtorrent 移植

## P5 落地说明（2026-10-24，首版已构建）

范围：通用网页抓取 + 批量入队。BT 引擎不参与编译（`WITH_BT=0`）。

新增源文件（`src/`，build.sh 通配自动收编）：

| 文件 | 职责 |
|---|---|
| `DLCrawler.h/.m` | 抓页面 + 正则解析 + 分类 + 过滤 + WebView 回退调度 |
| `DLWebRenderer.h/.m` | 隐藏 `WKWebView` 渲染兜底，取 `outerHTML`，超时 25s |
| `DLCrawlViewController.h/.m` | 「抓取」Tab：地址输入 / 过滤选项 / 结果多选 / 批量入队 |

改动：

- `AppDelegate`：Tab 变成「下载 / 抓取 / 设置」（WITH_BT=1 时末尾多一个「BT」）。
- `build.sh`：链接加 `-framework WebKit` 与 Cryptexes 框架搜索路径；**C 编译提到 ObjC 前面**；ObjC 编译改并发（`JOBS`，默认 4）；`WITH_BT` 开关。
- `res/Info.plist`：版本 `0.4.0`。

实现要点：

- **解析**：`(?i)(?:href|src|data-src|data-original|data-url)\s*=\s*("…"|'…')`，支持 `<base href>`、相对路径、`&amp;` 与数字实体；跳过 `javascript:` / `mailto:` / `data:` / `#`。
- **过滤**：同域开关（`www.` 归一）、扩展名白名单（逗号/空格/中文逗号分隔，`*.mp4` 也认）、关键字（文件名或 URL）、用户正则（对完整 URL）。
- **分类**：视频 / 音频 / 图片 / 压缩包 / 文档 / 种子 / 其他，结果按分类排序。
- **回退**：静态抓取 HTTP 失败、正文为空或解析 **0 条**时，自动用 `WKWebView` 渲染再解析一次；状态栏会标「（WebView 渲染）」。
- **入队**：逐条调 `DLDownloadEngine enqueueURL:fileName:`，文件名取 URL 末段（百分号解码），完成后可一键跳到下载列表。

验证点（真机一眼判断 P5 达成）：

- 底部第二个 Tab「抓取」，设置页版本 `0.4.0 (P5)`。
- 贴一个静态资源页 → 「找到 N 条可下载链接」，列表带「视频 · 同域 · mp4」这类副标题。
- 扩展名填 `mp4` 后重抓 → 只剩视频；关键字/正则同理。
- 勾选几条 → 底部「入队 (n/N)」→ 提示已加入 → 下载列表出现对应任务。
- 找一个靠 JS 渲染的页面，状态应显示「（WebView 渲染）」。

已知局限（v1）：

1. 下载任务只带 URL，**不传 Referer / Cookie**——有防盗链的站点可能 403，v2 要把抓取时的请求头上带到 `DLTask`。
2. 正则解析不是 HTML 解析器，遇到注释里的链接、JS 字符串里的 `href=` 会误收；去重和分类能兜住大部分噪声。
3. 页面正文上限 5MB，超出截断；不做分页/翻页抓取。
4. `WKWebView` 兜底只等 `didFinish`，对无限滚动/懒加载页面只能拿到首屏。
5. 不做登录态、不做验证码、不做 Cloudflare 绕过。

## 构建环境说明

- 交叉编译只需要 clang + ld64.lld + iPhoneOS SDK，不需要 Xcode 工程
- 产物无法在构建机上运行，网络与协议行为只能装机验证
- 装机验证一轮 = 打包 → 签名 → 安装 → 实测，节奏慢，所以每期都交付一个可安装的 IPA

## P6 说明：libtorrent 内核移植（2026-10-29 起）

**目标**：把 iTorrent 用的 BT 内核（libtorrent 2.0.11）移植进 DLBox，替换 P4 冻结的自研引擎。协议栈交给 libtorrent，DLBox 只写封装和 UI。

### 云端编译（不在本地编 C++）

libtorrent 166 个 C++ 文件在本地编要一个多小时，改到 GitHub Actions 的 macOS runner 上编：

- 仓库：`github.com/C1720/dlbox-ltbuild`（public，Actions 免费）
- workflow：`.github/workflows/build.yml`（由 作者手动点 Run workflow 触发）
- 编出：`libtorrent-rasterbar.a` + `libssl.a` + `libcrypto.a` + 头文件，打包成 `libtorrent-ios-arm64.tar.gz` 发 Release（tag `lt-2.0.11`）
- 本地解包到 `$LT_ROOT`（默认 `$HOME/dlbox-deps/prebuilt`），`build.sh` 通过 `LT_ROOT` 引用

关键编译参数（对齐 iTorrent 官方）：`-DTORRENT_HAVE_MMAP=0`、`-Ddeprecated-functions=OFF`、`webtorrent=OFF`、静态库、arm64、deployment target 14.0、boost 1.86.0（仅头文件）、OpenSSL 3.0.15（`ios64-cross`）。

### 踩过的坑（改 workflow 时别再犯）

1. **CMake 3.31 忽略 `BOOST_ROOT`**，必须再传 `-DBoost_INCLUDE_DIR=...`。
2. **Xcode 生成器不能 `cmake --build ... -- -j8`**：`-j8` 会被透传给 xcodebuild，它不认 → 打印 usage 并 exit 64。用 `--parallel`。
3. **打包阶段路径**：`LIB=$(find "$ROOT/work/lt-build" ...)` 要用绝对路径，脚本中途 `cd "$ROOT"` 后相对路径会失效。
4. **`gh release create` 需要仓库上下文**：workflow 里必须有 `actions/checkout`，并给 `gh` 传 `--repo`。
5. **ABI 命名空间**：库用 `-Ddeprecated-functions=OFF` 编译 → `TORRENT_ABI_VERSION=3` → 符号在 `libtorrent::v2::` 里。DLBox 侧编 `.mm` 必须同样加 `-DTORRENT_NO_DEPRECATE -DTORRENT_HAVE_MMAP=0`，否则一堆 undefined symbol。
6. **链接**：要补 `-framework SystemConfiguration`（libtorrent 的 ip_notifier 用 SCNetworkReachability），以及 `$SDK/usr/lib/libz.1.tbd`、`libiconv.2.tbd`（不是 `-lz`/`-liconv`）。

### 本地集成

| 文件 | 职责 |
|---|---|
| `src/DLBTLib.h/.mm` | libtorrent 的 ObjC++ 封装：session 生命周期、alerts 线程、magnet/torrent 添加、暂停/继续/删除、限速、fastresume 持久化 |
| `src/DLBTTorrentsViewController.h/.m` | 第 4 个 Tab「BT」：任务列表、粘贴/输入 magnet、导入 .torrent、暂停继续、滑动删除（可选删文件）、全局限速、详情 |

- `build.sh` 新增 `WITH_LT`（默认 1）：编 `src/*.mm`（C++17）、链接 `libtorrent-rasterbar.a`/`libssl.a`/`libcrypto.a`/`libc++.1.tbd`。
- `AppDelegate` 按 `DLBOX_WITH_LT` 挂 BT Tab（旧的 `DLBOX_WITH_BT` 自研引擎仍保留为存档）。
- 版本 `0.5.0 (P6)`。

### 已知边界

1. iOS 切后台后 libtorrent 的 socket 会被系统挂起（没有后台保活），回前台自动继续。
2. 首次启动 session 初始化 1–2 秒。
3. 下载文件与 HTTP 下载同目录（`Documents/dlbox/downloads/`）。
4. 尚未做：BT 任务与 HTTP 任务合并到同一列表、通知、单任务限速、文件选择下载。

### 验证点

设置页版本 `0.5.0 (P6)`；底部第 4 个 Tab「BT」；贴 magnet → 「获取元数据」→「下载中」带速度/peer；暂停/继续/删除可用；限速生效。

---

## P6.1 修复：抓取页「根本用不了」（2026-10-29）

作者装了 P6 后实测抓取功能完全不可用（"根本就用不了"）。自查代码 + 本地复现，根因三处：

1. **`NSURLSessionDataTask` 忘写 `resume`（致命）**
   `DLCrawler.m` 里 `[[NSURLSession sharedSession] dataTaskWithRequest:...]` 的返回值被直接丢弃。`dataTask` 创建后处于 suspended，不调用 `resume` 请求永远不会发出，completion 永不回调 —— 界面永远停在「抓取中…」、右上角按钮永久置灰。这就是点「开始抓取」毫无反应的原因。
   修复：拿到 `NSURLSessionDataTask *task` 并 `[task resume]`（P4 的 `DLBTSession.m:57` 有同样写法，已随 P4 冻结，不再理会）。

2. **UA 被镜像站 WAF 拦（403）**
   `DLCrawler` 硬编码 Safari UA。实测清华 TUNA 对含 `AppleWebKit` 的 UA（Mac Safari / iOS Safari / Windows Chrome）一律 **403**，对 `curl`、`Wget`、无 UA、自定义 UA 返回 **200**。
   修复：`fetchHTML:uaIndex:options:completion:` 支持多套 UA，遇到 403 / 406 / 429 / 451 自动换下一套重试，第二套为 `DLBox/0.5.2 (iPhone; iOS; +https://github.com/C1720/DLBox-Public)`。

3. **结果全是目录/排序垃圾**
   nginx / Apache autoindex 页里的 `../`、`/`、`?C=N;O=D`、`SHA256SUMS` 以及页面自身的 css/js/字体/ico 都会被抓进列表，把真正的文件淹掉。
   修复：跳过路径为空或以 `/` 结尾的链接、纯 `C=`/`O=` 排序 query、`css/js/mjs/map/woff/woff2/ttf/otf/eot/ico` 扩展名。

顺手补的两处：
- 抓取 45 秒无回调 → 强制解锁界面并提示「抓取超时」，不再永久卡死（`DLCrawlViewController.m`）。
- `DLWebRenderer` 取宿主的 window 改为遍历非隐藏 window，避免 `windows.firstObject` 落到系统 window 上导致渲染不出内容。
- `build.sh` 写版本号改为按 `CFBundleShortVersionString` / `CFBundleVersion` 的键位替换（原来靠 `<string>0.5.0</string>` 字面量匹配，改版本号后会静默失效，导致 IPA 里版本没变）。

### 本地复现结果（Python 复刻 parseHTML 同一套规则，打真实页面）

| 页面 | 结果 |
|---|---|
| `mirrors.tuna.tsinghua.edu.cn/ubuntu-releases/24.04/` | UA#1 403 → UA#2 200，解析 **48 条**（压缩包 9 / 种子 6 / 其他 33，其他为 zsync、list、manifest、SHA256SUMS） |
| `mirrors.ustc.edu.cn/ubuntu-releases/24.04/` | UA#1 直接 200，解析 **43 条**（压缩包 8 / 种子 6 / 其他 29） |

### 产物

`$IPA_DIR/DLBox-P6.1.ipa`（3.5 MB，md5 `378cf66709e36b7bacb1b2dec28edcc0`），版本 `0.5.1 (P6.1)`。

### 真机验证点

1. 设置页版本显示 `0.5.1 (P6.1)`。
2. 「抓取」页贴 `https://mirrors.tuna.tsinghua.edu.cn/ubuntu-releases/24.04/` → 点「开始抓取」→ **1–3 秒内**出现 40+ 条结果（不再卡在「抓取中…」）。
3. 结果里 `.iso` 在「压缩包」、`.torrent` 在「种子」，不再混进 `?C=N;O=D` 这类条目。
4. 勾几条小文件（`.manifest` / `.zsync`）→ 底部「入队」→ 下载页能看到任务并跑完。


---

## P6-fix2：核心引擎的一轮清理（2026-10-30）

> 命名说明：上一版 `DLBox-P6.1.ipa`（0.5.1）没按 `-fixN` 约定命名，实际等同于 P6-fix1；本版起回到约定，为 `DLBox-P6-fix2.ipa`（0.5.2）。

这一轮是把核心代码通读一遍后修出来的问题，不新增功能。

### 1. 分段拼接改成流式（防闪退）

`DLSegmentDownloader/finish` 原来用 `[NSData dataWithContentsOfFile:part]` 逐段整段读入内存再写出。8 段下 4 GB 的 ISO 每段 500 MB，iOS 必被 jetsam 杀掉，表现为「下到 99% 闪退」。

- 改为 `readDataUpToLength:error:` 按 1 MB 块搬运，峰值内存降到 1 MB 级；
- 拼接前先删除目标文件（`createFileAtPath:` 对已存在文件**不截断**，会追加到旧内容后面，产出坏文件）；
- 写盘失败时删除半成品并跳过 `onFinished`。

### 2. 分片产物大小校验

`segmentedTaskFinished:` 在 move 前用 `attributesOfItemAtPath` 比对 `totalBytes`，不一致直接判失败、删临时文件，不再把坏文件塞进 `downloads/`。

### 3. 落盘从 0.5s 降到 2s

`store save` 是「整表序列化 + 原子写」，原来跟随 0.5s 的进度通知每 2 秒写 4 次，而且在串行的 `foregroundQueue` 上执行，会堵住所有分段的回调。现在 UI 通知仍 0.5s，落盘独立节流到 2s（进度本来就不需要持久化，崩溃后按 part 文件大小重建）。

### 4. 续传进度修正

`DLSegmentDownloader/start` 走「已有 segments」分支时，原来不重算 `receivedBytes`，进度条和实际分片大小对不上。现在按 part 文件实际长度累加，并 `syncToTask`。

### 5. 速度计算平滑

`updateSpeedForTask` 改为指数平滑（0.6 旧 + 0.4 新），暂停恢复后不再先显示一个离谱的高值。这是「速度虚标」观感的来源之一。

### 6. 探测被拒时回退后台整段

`handleProbeResponse` 遇到 403 / 405 / 501（防盗链站常只放行不带 Range 的请求）时，不再直接判失败，而是把任务切到 background 模式重试一次。

### 7. 其他

- `enqueueURL:` 对「同 URL 且未完成」的任务查重，返回已有 taskId，避免重复下载；
- `DLTaskStore` 加 taskId → task 字典索引，`taskWithId:` 从 O(n) 变 O(1)（每个数据块都要查两次）；
- `applySettings` 后立即 `pump`，改并发数不用等下一个事件；
- `didFinishDownloadingToURL` 落盘失败时不再把 `receivedBytes` 标成 totalBytes（避免「100% 但失败」）；
- `DLRateLimiter` 从 20ms 轮询改为按缺口精确 sleep（限速时不再每秒空转 50 次）。限速仍是阻塞实现，这一点记在「已知局限」里。

### 8. build.sh

- `BOOST_ROOT` 参数化，去掉写死的 libtorrent include 路径；
- `WITH_LT=1` 但预编译库缺失时**前置报错退出**，而不是留到链接期报 undefined symbols；
- `VER` 默认值跟到 0.5.2；
- 删掉一处空 `case`；
- 并行编译某个文件失败时 kill 掉其余子进程；
- 打包后自检 `CFBundleShortVersionString`，与 `$VER ($STAGE)` 不一致直接失败（P6.1 那次版本没写进去就是因为没人校验）。

### 已知局限（本轮没改）

1. **限速仍会阻塞下载回调队列**。默认不限速（0）时零影响；要彻底解决需要改用 `NSURLSessionTask suspend/resume` 节流，风险比收益大，留到后面。
2. `DLDownloadEngine.m` 已经 690 行，调度 / 委托 / 分段 / 后台 / 持久化混在一个文件里，读起来吃力，后续可拆。
3. 云端 CI 与后续几轮排查的开销没有记录，只保留技术结论。

### 产物

`$IPA_DIR/DLBox-P6-fix2.ipa`，版本 `0.5.2 (P6-fix2)`。

### 真机验证点

1. 设置页版本 `0.5.2 (P6-fix2)`。
2. 下载一个 300–800 MB 的文件，**走后不再闪退**，进度到 100% 后文件大小与服务器一致。
3. 下载中切后台再回来，进度条不会倒退或跳变。
4. 把限速设成 2 MB/s，速度读数应稳定在 1.9–2.1 之间，不再出现长时间 0 或忽高忽低。
