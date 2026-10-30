# DLBox

一个**没有 Xcode**、纯命令行交叉编译出来的 iOS 下载器。产物是未签名 IPA，自行签名安装。

当前版本：**0.5.2 (P6-fix2)** · 最低 iOS 14.0 · arm64 · 无第三方 UI 依赖

---

## 功能

### HTTP / HTTPS 下载

- **多段并发加速**：1–8 段并发（Range 请求），默认 4 段；服务器不支持 Range 时自动降为单段
- **断点续传**：分段模式按 `part-*` 分片文件续传，后台模式用 `NSURLSession` 的 resume data
- **两种下载模式**：分段加速（快，切后台会被系统挂起） / 后台整段（慢一些，锁屏不中断）
- **并发任务数** 1–6，可在设置页调整，改完立即生效
- **全局限速**：256 KB/s – 5 MB/s，0 为不限速
- 同名文件自动重命名成 `xxx (1).mp4`，不会互相覆盖
- 进度每 2 秒落盘一次，App 被杀后重开可续传

### 网页抓取

- 贴一个网页地址，把页面里的可下载链接扒出来，勾选后批量入队
- 静态 HTML 正则解析优先；一条都没抓到（JS 渲染页）时自动用隐藏 `WKWebView` 再渲染一次
- **过滤器**：只抓同域、是否包含图片、扩展名白名单、文件名关键字
- **UA 自动降级**：先用桌面 Safari UA，被 WAF 拦（403/406/429/451）时换自定义 UA 重试一次
- 会自动跳过目录链接、`?C=N;O=D` 这类排序参数、页面自身的 css/js/字体/图标
- 结果按「视频 / 音频 / 压缩包 / 文档 / 种子 / 图片 / 其他」分组排序，标出同域 / 跨域

### BT 下载（libtorrent 2.0.11）

- 内核与 [iTorrent](https://github.com/XITRIX/iTorrent) 同源：libtorrent 2.0.11 + OpenSSL 3.0.15
- 支持 **magnet**、**`.torrent` 导入**（系统文件选择器）、**DHT / PEX / ut_metadata**
- 任务列表显示状态「获取元数据 → 下载中」、速度、peer 数、进度
- 暂停 / 继续 / 左滑删除（可选连同文件一起删）
- 全局限速（KB/s，0 = 不限）

### 其它

- 「设置 → 诊断日志」：`[BT]`、`[Crawl]` 前缀的日志可直接定位问题
- 设置页显示版本号，便于确认装的是哪一版

---

## 界面

底部四个 Tab：

| Tab | 作用 |
|---|---|
| **下载** | 任务列表、进度、暂停/继续、左滑删除 |
| **抓取** | 网页扒链接、过滤、批量入队 |
| **设置** | 并发数、分段数、限速、下载模式、允许 HTTP、诊断日志、版本号 |
| **BT** | 磁力/种子任务、限速、详情 |

---

## 安装

1. 从 [Releases](https://github.com/C1720/DLBox-Public/releases) 下载 `DLBox-*.ipa`（未签名）
2. 用 Sideloadly / AltStore / TrollStore 等工具自签名安装（需要自备证书，或已越狱/巨魔环境）
3. 首次打开会问要不要允许蜂窝网络下载

> 本仓库不提供签名服务，IPA 里也没有任何描述文件。

---

## 使用

**下载一个文件**

下载页右上角 `+` → 粘贴链接 → 直接入队。文件名取 URL 最后一段，可手动改。

**批量抓一个目录页**

抓取页 → 贴页面地址 → 点右上角「开始抓取」→ 等 1–3 秒出结果 → 勾选 → 底部「入队」。

推荐用镜像站目录页试手，例如：

```
https://mirrors.tuna.tsinghua.edu.cn/ubuntu-releases/24.04/
https://mirrors.ustc.edu.cn/ubuntu-releases/24.04/
https://mirrors.tuna.tsinghua.edu.cn/gnu/hello/
```

**下 BT**

BT 页右上角 `+` → 粘贴 magnet / 输入磁力链接 / 从文件导入 `.torrent`。磁力链接需要几秒到十几秒做 DHT 找 peer，状态会从「获取元数据」变成「下载中」。

---

## 构建

### 依赖

| 依赖 | 默认位置 | 覆盖变量 |
|---|---|---|
| iOS SDK | `$HOME/theos/sdks/iPhoneOS16.5.sdk` | `SDK` |
| 编译器 | `clang`（PATH 中） | `CLANG` |
| 链接器 | `ld64.lld`（PATH 中） | `LD` |
| libtorrent 静态库 | `$HOME/dlbox-deps/prebuilt` | `LT_ROOT` |
| Boost 头文件 | `$HOME/dlbox-deps/boost` | `BOOST_ROOT` |

脚本不假设任何固定目录，全部可用上表的环境变量覆盖。换成你自己的路径直接传变量即可，见下方示例。

工具链要点：入口必须是 `-e _main`（不能靠 `@main`），`libSystem.B.tbd` 要显式链接，构建过程不需要符号链接。

如果 `clang` 或 `ld64.lld` 不在 `PATH` 里（theos 工具链常见装在别处），用 `CLANG=/path/to/clang LD=/path/to/ld64.lld` 指定。

### 取 libtorrent 静态库

```sh
DEPS="$HOME/dlbox-deps/prebuilt"
mkdir -p "$DEPS"
curl -L -o /tmp/lt.tar.gz \
  https://github.com/C1720/dlbox-ltbuild/releases/download/lt-2.0.11/libtorrent-ios-arm64.tar.gz
tar xzf /tmp/lt.tar.gz -C "$DEPS"    # 得到 include/ lib/ VERSION.txt
```

不想用默认目录就自己放，构建时把 `LT_ROOT` 指过去就行。

### 打 IPA

```sh
sh build.sh P6-fix2          # 全流程：C → ObjC → 链接 → 打包
sh build.sh P6-fix2 1        # 只编 C（BT 引擎已冻结，几乎秒过）
sh build.sh P6-fix2 2        # 只编 ObjC（并发 4，耗时视机器而定）
sh build.sh P6-fix2 3        # 只链接
sh build.sh P6-fix2 4        # 只写版本号 + 打包
```

产物：`$IPA_DIR/DLBox-<期号>.ipa`（`IPA_DIR` 默认是仓库下的 `out/`，未签名，约 3.5 MB）。

```sh
# 依赖放在别处、产物换个目录
SDK="$HOME/theos/sdks/iPhoneOS16.5.sdk" \
LT_ROOT="$HOME/dlbox-deps/prebuilt" \
BOOST_ROOT="$HOME/dlbox-deps/boost" \
IPA_DIR="./out" \
sh build.sh P6-fix2
```

**必须按 1 → 2 → 3 → 4 的顺序跑**，C 编译最快、出错最早暴露；打包阶段会自检 `CFBundleShortVersionString` 是否和命令行给的一致，不一致直接报错退出。

### 环境变量

| 变量 | 默认 | 作用 |
|---|---|---|
| `VER` | `0.5.2` | 版本号主体，最终写成 `$VER ($STAGE)` |
| `STAGE` | `P5` | 第一个参数，期号，写进版本号和文件名 |
| `WITH_LT` | `1` | 链接 libtorrent，缺库会前置报错 |
| `WITH_BT` | `0` | 把 P4 冻结的自研 BT 引擎也编进去（存档用） |
| `JOBS` | `4` | ObjC 并行编译数 |
| `SDK` / `CLANG` / `LD` | 见上表 | 工具链路径 |
| `LT_ROOT` / `BOOST_ROOT` | 见上表 | 依赖路径 |

```sh
# 不要 BT，只编 HTTP + 抓取
WITH_LT=0 sh build.sh P6-fix2

# 6 个并发编译
JOBS=6 sh build.sh P6-fix2 2
```

---

## 目录

```
src/      ObjC / ObjC++ 源码（UI + 引擎桥接）
csrc/     自研 BT 引擎（P4 冻结存档，默认不参与编译）
res/      Info.plist / 图标
tools/    GitHub Actions workflow（libtorrent 云端编译）
build/    编译中间产物与 Payload（每次全量重建）
build.sh  一键编译打包
SPEC.md   架构、接口、分期与踩坑记录（新会话先读这个）
```

核心文件：

| 文件 | 职责 |
|---|---|
| `src/DLDownloadEngine.m` | 调度、NSURLSession 委托、后台/分段两条下载路径、速度统计 |
| `src/DLSegmentDownloader.m` | 分段 Range 下载、分片写盘、流式拼接 |
| `src/DLTaskStore.m` | `tasks.plist` 持久化、resume data、分片目录 |
| `src/DLRateLimiter.m` | 全局令牌桶限速 |
| `src/DLCrawler.m` | 网页解析（`parseHTML:` 纯函数，可单测） |
| `src/DLWebRenderer.m` | 隐藏 WKWebView 渲染兜底 |
| `src/DLBTLib.mm` | libtorrent 的 ObjC++ 封装（session、alerts 线程、限速） |

---

## 下载流程

```
入队 → probe（Range: bytes=0-0）
         ├─ 206 → 支持 Range → 按段并发 dataTask → part-N 文件
         │          └─ 全部完成 → 流式拼接到 .tmp-<id> → 校验大小 → 移到 downloads/
         ├─ 200 → 不支持 Range → 单段顺序下载
         └─ 403/405/501 → 回退「后台整段」模式重试一次
```

- 拼接按 1 MB 块搬运，不会把整个分片读进内存
- 拼完会比对 `Content-Length`，对不上直接判失败，不把坏文件塞进下载目录
- 文件落在 `Documents/dlbox/downloads/`，分片在 `Documents/dlbox/parts/`

---

## 云端编译 libtorrent

`tools/github-actions/build-libtorrent.yml` 是 GitHub Actions（macOS runner）上的交叉编译脚本：拉 libtorrent 2.0.11 + Boost 1.86 + OpenSSL 3.0.15，编成 iOS arm64 静态库并发 Release。

工作流在 https://github.com/C1720/dlbox-ltbuild ，**手动点 Run workflow** 触发，约 7 分钟。产物 `libtorrent-ios-arm64.tar.gz` 约 6.9 MB。

参数与 iTorrent 官方一致：`TORRENT_HAVE_MMAP=0`、`deprecated-functions=OFF`，启用 DHT、PEX、ut_metadata。

---

## 版本历史

| 版本 | 内容 |
|---|---|
| **0.5.2 (P6-fix2)** | 分段拼接改流式（修大文件闪退）、分片大小校验、落盘节流、续传进度修正、速度平滑、探测失败回退后台、抓取页 resume/UA 修复、构建自检 |
| 0.5.1 (P6.1) | 抓取页救命修复：`dataTask` 漏 `resume`（点了没反应）、UA 被镜像站 403、结果混进目录垃圾 |
| 0.5.0 (P6) | 换成 libtorrent 2.0.11 内核，新增 BT Tab，支持 magnet/.torrent |
| 0.4.0 (P5) | 网页抓取 + 批量入队 |
| 0.3.x (P4) | magnet / DHT / PEX / 做种，自研引擎，**已烂尾冻结** |
| 0.2.x (P3) | 自研 BT 核心：bencode、tracker、peer wire、分片、写盘 |
| 0.1.x (P2) | 任务列表 UI、多段并发加速、设置页 |
| 0.0.x (P1/P0) | HTTP 引擎、骨架 |

---

## 已知限制

1. **抓取不带 Referer / Cookie**：防盗链站点抓到的链接入队后可能 403。探测被拒时会自动回退「后台整段」再试一次，但不保证成功。
2. **限速会阻塞下载回调队列**：默认不限速时无影响；限速到很低的值时进度刷新会变慢。彻底解决要改用 `NSURLSessionTask suspend/resume` 节流。
3. **BT 切后台会被系统挂起**：回前台自动继续，但没有后台保活。
4. **未做**：完成通知、RSS、WebDAV、内置播放器 / 画中画 / AirPlay、Dynamic Island、BT 与 HTTP 合并到一个列表。
5. **签名**：IPA 全是未签名产物，必须自行处理。

---

## 相关

- [SPEC.md](SPEC.md) — 架构、接口、分期、踩坑记录（新会话请先读）
- [Releases](https://github.com/C1720/DLBox-Public/releases) — 历史 IPA 归档
- [C1720/dlbox-ltbuild](https://github.com/C1720/dlbox-ltbuild) — libtorrent 云端编译
- [XITRIX/iTorrent](https://github.com/XITRIX/iTorrent) — BT 部分的功能参考与内核来源

---

## 许可

本项目以 **GPL-3.0** 发布，全文见 [LICENSE](LICENSE)。

- BT 部分（`src/DLBTLib.*`、`src/DLBTTorrentsViewController.*`）的接口与行为参考了 [XITRIX/iTorrent](https://github.com/XITRIX/iTorrent)（GPL-3.0），内核为 libtorrent 2.0.11（BSD-3-Clause）；
- 其余代码为原创，可自由修改分发，但需保留同等的开源许可。
