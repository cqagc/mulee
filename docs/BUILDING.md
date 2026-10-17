# 构建与打包说明

## 日常构建

需要 Apple Silicon、支持 macOS 26 的 Xcode / Command Line Tools 和 XcodeGen。
以下工具只在构建机使用，运行 Mulee.app 不需要 Homebrew：

```sh
brew install xcodegen cmake boost autoconf automake libtool gettext pkgconf
git submodule update --init --recursive  # 仅缓存未命中、需要编译源码时必需
xcodegen generate
xcodebuild -project Mulee.xcodeproj -scheme Mulee -destination 'platform=macOS' -derivedDataPath build/dd build
```

## worktree 共享缓存

aria2、torrentd、aMule 三个脚本优先使用已初始化子模块自身的 HEAD；子模块为空时，读取父仓库索引中的
`ThirdParty/<模块>` gitlink，不会误用父仓库 HEAD。仅缓存未命中、需要源码编译时
才要求相应子模块初始化；wxWidgets 的 PCRE2 / Expat 嵌套模块也仅在编译 wx 时校验。
因此新 worktree 可直接复用指向主仓库 `build/thirdparty` 的符号链接，无需初始化子模块。
构建工具和 Boost 头文件仍需安装。

缓存目录统一用 `pwd -P` 解析物理路径；缓存键不包含缓存目录路径。
torrentd 显式用 `xcrun --sdk macosx --show-sdk-path`，统一 Xcode 与 standalone 的 SDK 路径别名。
旧 torrentd 键包含该路径，CMake / configure 的确会在构建树和安装元数据中记录绝对路径，
但命中缓存时 torrentd 直接使用安装后的头文件、静态库重新编译 `Helpers/mulee-torrentd/`，
aria2 / aMule 则复制已链接的二进制，不重用构建树或 CMake 导出目标，所以可跨 worktree 复用。
签名、系统动态库校验和 App 封印处理保持原样。

编译成功时同时缓存许可证文本：torrentd 使用 `<键>/licenses/<组件>/`，
aria2 使用 `aria2/<键>/licenses/`，aMule 使用 `amuled/<键>/licenses/<组件>/`。
7-Zip 使用 `7zip/<键>/licenses/`，缓存键始终取父仓库索引记录的 gitlink。
打包只读取这些缓存文本，不读取当前 worktree 的子模块源码。

### 旧缓存一次性迁移（2026-10-15）

先核对子模块提交、编译器、SDK、Boost、架构、部署目标及全部功能参数一致，
再以 `cp -cR <旧键目录> <新键目录>` 克隆完整目录（不支持克隆时用普通复制），
只在新目录中补齐 `licenses/`，保留旧目录不变。不运行旧 CMake / configure 构建树。
本次核对为 AppleClang 21.0.0.21000334、SDK 27.0、Boost 1.92.0、arm64、macOS 26.0；
OpenSSL `configdata.pm`、libtorrent / aMule `CMakeCache.txt`、aria2 `config.log` 中参数
与脚本一致，主仓库子模块 HEAD 与本 worktree gitlink 一致。

| 缓存 | 旧目录（相对缓存根） | 新目录（相对缓存根） |
|---|---|---|
| OpenSSL + libtorrent | `b679411f2c2888ebf113a077fa23d7eaabfd8dd997d508a6c5206d8496d9f147` | `972a95fb886e876494b981f77061e7edd4ec895735e0e44f449f5ceb95cb0611` |
| aria2 | `aria2/930e68e0c7363ef921ebd7a477cca15f3810e7c930423d9548c6e5b39c0406aa` | `aria2/278a8c4a8c2671466614402705022d97478a422d6c6d6c4f947f32c6f87b193f` |
| aMule（amulecmd=OFF） | `amuled/b661975accc4b13de090ae299064fa956412f789b16e3a48d78e2987da92afe1` | `amuled/f614d02fc5fd85303f1bb27e7d0019637560eda25345535b4fc393f3d65604a6` |

wxWidgets 和 Crypto++ 的键未变，直接使用现有完整缓存。许可证分别从固定版本源码、
旧缓存源码副本复制，并沿用原来的 Boost 文本提取规则。
一次性迁移步骤和映射日志保存在 `build/cache-verification/migrate.py`、`migration.log`；
脚本拒绝覆盖非空的新键目录。aMule standalone 的 ON 键没有完整旧缓存，不能把 OFF
目录冒充 ON 目录；找到的 spike amulecmd 依赖 Homebrew 动态库且 minos 为 27.0，未迁移。

本 worktree 空子模块验收：aria2 standalone 命中缓存约 2 秒，torrentd 静态依赖命中，
自身 C++ 源码仍照常编译（约 17 秒）。aMule standalone 因没有 ON 缓存而在编译前报错，
该项验收未通过，未重编 wx / aMule。Xcode 三个打包阶段全部命中，App 包含三个 Helpers，
`codesign --verify --deep --strict` 通过，16 个许可证文件的相对路径与 SHA-256 均与原 App 一致。
为限定生成文件范围，本次在 `build/cache-verification/` 使用临时 spec 运行
`xcodegen generate`（只调整生成路径和原脚本的 SRCROOT），随后 `xcodebuild ... build` 成功；
正式 `project.yml`、Info.plist 和工程文件未改动。


## aria2 源码构建与打包

`Mulee` target 的 `postBuildScripts` 阶段调用 `scripts/build-aria2.sh`，从固定的
`ThirdParty/aria2`（release-1.37.0）编译 `Contents/Helpers/aria2c`。不安装或复制 Homebrew aria2。
脚本通过只读 `git archive` 导出精确提交，在构建副本中运行 `autoreconf -i`、configure 和 make，
不会修改子模块。构建及辅助进程使用 `LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8`。

- arm64、`-mmacosx-version-min=26.0`、系统 libc++，zlib 使用 macOS SDK 系统库。
- `--with-appletls --without-openssl --without-gnutls`：HTTPS 使用 AppleTLS 和系统钥匙串信任，
  不需要 `OPENSSL_MODULES`、OpenSSL provider 或单独的 CA 文件。
- 开启 Metalink，XML 解析用 macOS SDK 自带的 libxml2（`/usr/lib/libxml2.2.dylib`，系统库，不随包分发）。
- 关闭 BitTorrent、SQLite、Expat、libssh2、c-ares、NLS、libuv 及其他外部密码库。
  aria2 只负责 HTTP / HTTPS / FTP 和 Metalink；BT 由 libtorrent 负责。
- 每次校验 `otool -L` 只出现 `/usr/lib/`、`/System/`，架构仅 arm64、`minos` 为 26.0，
  `aria2c --version` 必须包含 HTTPS、GZip、AppleTLS 和 Metalink。

缓存为 `${MULEE_THIRDPARTY_CACHE:-$SRCROOT/build/thirdparty}/aria2/<缓存键>/`，
键包含子模块提交、configure / 编译参数、SDK、工具链和构建脚本。命中后跳过编译。
`BUILD_JOBS` 控制编译并行度（默认 8）。独立构建与集成测试：

```sh
scripts/build-aria2.sh --standalone
MULEE_ARIA2C="$PWD/build/thirdparty/bin/aria2c" swift test --package-path Packages/MuleeCore --filter Aria2
```

standalone 产物为 `<cache>/bin/aria2c`。集成测试只使用 `MULEE_ARIA2C`，没有可执行产物时跳过。
引擎按显式路径、App 的 `Contents/Helpers/aria2c`、`MULEE_ARIA2C` 顺序查找，不回退到 Homebrew。

Xcode 脚本关闭用户脚本沙盒，以便在缓存目录编译、打包并签名；构建阶段每次运行。
增量构建会清除旧的 `Contents/Frameworks/aria2`、`Contents/Resources/aria2`，以及仅旧 aria2
使用的 Homebrew 依赖许可证；保留 BT / 电驴引擎共用的 OpenSSL、Boost 等许可证。

## 解压工具 7-Zip

`Mulee` 在 amuled 之后运行 `Bundle 7-Zip`，从官方子模块 `ThirdParty/7zip`
（ip7z/7zip 26.04）编译并打包 `Contents/Helpers/7zz`。运行机器无需 Homebrew。
脚本只读导出父仓库索引 gitlink 对应的提交，在构建副本的 `CPP/7zip/Bundles/Alone2`
运行上游推荐的 `make -f ../../cmpl_mac_arm64.mak`，不修改子模块，不引入外部库。

- 固定 arm64、`-mmacosx-version-min=26.0`、显式 macOS SDK；构建及子进程使用
  `LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8`。
- 校验架构仅 arm64、`LC_BUILD_VERSION minos` 为 26.0，`otool -L` 只有 `/usr/lib/`
  和 `/System/`；`7zz i` 必须列出 7z、zip、Rar、Rar5、tar、gzip、Split 和 AES。
  支持 ZIP / 7z / RAR（含 RAR5）解压、tar.gz、分卷及加密压缩包；RAR 仅解压。
- 缓存为 `${MULEE_THIRDPARTY_CACHE:-$SRCROOT/build/thirdparty}/7zip/<键>/`，键包含父仓库
  gitlink、make 参数、SDK、工具链及脚本摘要。仅缓存未命中时需要初始化子模块。
  `BUILD_JOBS` 控制 make 并行度，默认 8。
- Xcode 阶段原子替换 helper，使用 `EXPANDED_CODE_SIGN_IDENTITY` 和 hardened runtime 签名；
  无身份时 ad-hoc，有身份时加 `--timestamp`。增量封印失效时保留 entitlements / flags 重签 App。
- 上游 `DOC/License.txt` 在编译成功时缓存，随包放入
  `Contents/Resources/Licenses/7zip/License.txt`，包含 GNU LGPL、BSD 3-clause、BSD 2-clause
  及 unRAR 限制；同目录说明文件记录精确源码提交地址。

```sh
scripts/build-7zip.sh --standalone
MULEE_7ZZ="$PWD/build/thirdparty/bin/7zz" swift test --package-path Packages/MuleeCore --disable-sandbox
MULEE_7ZZ="$PWD/build/thirdparty/bin/7zz" TEST_RUNNER_MULEE_7ZZ="$PWD/build/thirdparty/bin/7zz" \
  xcodebuild -project Mulee.xcodeproj -scheme Mulee -destination 'platform=macOS' test
```

standalone 产物为 `<cache>/bin/7zz`。查找顺序为显式路径、`Bundle.main` 的
`Contents/Helpers/7zz`、环境变量 `MULEE_7ZZ`，不回退到 Homebrew；缺失时提示重新安装 Mulee。
MuleeCore 与 App 解压集成测试只用 `MULEE_7ZZ` 生成夹具，没有可执行路径时跳过；
App 测试通过默认解压服务验证包内工具。Xcode 测试进程用 `TEST_RUNNER_MULEE_7ZZ` 传递该变量。

2026-10-16 验证：MuleeCore 全量复跑 184 项通过，App 189 项通过，解压集成测试均实际运行；
首次核心测试曾遇到既有 `Ed2kUnitTests.stateLock` 失败，未改动电驴代码。
standalone、空子模块缓存命中、Xcode 增量构建均通过，7-Zip 阶段实际修复增量封印；
App 内 7zz 为 arm64、minos 26.0，仅链接系统库，ad-hoc hardened runtime 签名，
`codesign --verify --deep --strict` 通过。直接用包内工具解开加密文件头的密码 7z、中文文件名 ZIP、
tar.gz 与分卷 7z，文件名及内容均一致。RAR / RAR5 通过 `7zz i` 注册能力检查，未使用真实 RAR 夹具；
Developer ID 时间戳未实测。为限制生成文件范围，验收工程及所有日志位于 `build/`，
汇总为 `build/7zip-verification.log`。

## 签名与许可证

- 身份取 Xcode 的 `EXPANDED_CODE_SIGN_IDENTITY`；空值或 `-` 为 ad-hoc。
- helper 先以 `--options runtime` 签名，再由 Xcode 签 App；Developer ID 额外使用 `--timestamp`。
  仅链接系统库，无需 `disable-library-validation` entitlement。
- helper 原子替换，避免覆盖运行中的签名代码页；增量构建若 App 资源封印失效，保留 entitlements / flags 重签。

```sh
codesign --verify --deep --strict --verbose=2 build/dd/Build/Products/Debug/Mulee.app
otool -L build/thirdparty/bin/aria2c
vtool -show-build build/thirdparty/bin/aria2c
build/thirdparty/bin/aria2c --version
```

aria2 的 GPL-2.0-or-later 文本 `COPYING` 和 OpenSSL 链接例外 `LICENSE.OpenSSL`
随包放入 `Contents/Resources/Licenses/aria2/`，说明文件提供精确源码提交地址。
系统库不再分发，其他引擎的许可证见下文。

## Quick Look 预览扩展

`MuleeQuickLook` target（`MuleeQuickLook/`）是访达里按空格预览 .torrent 的扩展，打进
`Contents/PlugIns/MuleeQuickLook.appex`，与 App 一起签名公证。扩展开沙盒、只读 Quick Look
提供的文件、不联网，种子解析复用 MuleeCore 的 `TorrentFileInfo`；大于 20 MB 的文件不解析。
它有自己的字符串目录 `MuleeQuickLook/Resources/Localizable.xcstrings`。release.sh 的签名检查
递归遍历 App 内全部 Mach-O，已覆盖这个扩展。本地确认注册：

```sh
pluginkit -m -i com.cqagc.mulee.quicklook
```

## 已知限制

- **已解决：最低系统版本漂移**。aria2 从源码指定 macOS 26.0 构建并强制验证 minos，不再携带 minos 27 的 Homebrew 二进制。
- **已解决：gettext / SQLite 许可证复核项**。两者均未链接、未打包；gettext 仅是构建机的生成工具。
- **只有 arm64**：和 App 一致，不做 universal。
- 首次构建需要上述生成工具和已初始化子模块；运行机器无需这些工具、Homebrew 库或独立证书包。

## BT 辅助进程 mulee-torrentd

构建机需要 Xcode 命令行工具，以及 `brew install cmake boost`。缓存未命中时先初始化固定版本的源码子模块：

```sh
git submodule update --init --recursive
scripts/build-torrentd.sh --standalone
python3 -I scripts/test-torrentd.py
```

脚本在源码副本中编译 OpenSSL 3.5.9，再编译 libtorrent-rasterbar 2.0.15，最后用 C++17
编译 `Helpers/mulee-torrentd/`。不会修改 `ThirdParty/`。首次全量编译约 8 分钟；
静态依赖缓存在 `${MULEE_THIRDPARTY_CACHE:-$SRCROOT/build/thirdparty}/<缓存键>/`，
缓存键包含两个子模块提交号、编译参数、Boost 版本、工具链信息及
`Helpers/mulee-torrentd/patches/*.patch` 的文件名和完整内容，命中后跳过依赖编译。
libtorrent 先用 `git archive` 导出固定提交，再在缓存源码副本中依次应用补丁；
补丁不修改子模块，导出源码与辅助进程均继续使用 `-ffile-prefix-map` 清理本机路径。
`--standalone` 只产出 `<cache>/bin/mulee-torrentd`，可供命令行及 MuleeCore 集成测试使用：

```sh
build/thirdparty/bin/mulee-torrentd --state-dir "$PWD/build/torrent-state"
```

进程通过 stdin/stdout 的 JSON Lines 通信，协议见 `docs/TORRENTD-PROTOCOL.md`。
关闭 stdin 或发送 `shutdown` 会保存 resume data 并退出。构建及辅助进程的子进程环境使用
`LANG=en_US.UTF-8`、`LC_ALL=en_US.UTF-8`。自动测试只使用临时生成的数据和本机回环互传，
不依赖公网或第三方 tracker。

主机名解析结果全部位于 IPv4 `198.18.0.0/15`（含 IPv4 映射地址）时，torrentd 才启动真实地址查询。
普通或混合解析结果不触发公共 DNS；未将任意 IPv6 私有地址段视作假地址。
查询使用有网关、已启用的非隧道物理接口，通过 `IP_BOUND_IF` 和源地址绑定 IPv4 socket，
并行查询 A / AAAA。依次尝试 `223.5.5.5`、`119.29.29.29`、`1.1.1.1`、`8.8.8.8` 的 UDP 53，
截断时用同一服务器的 TCP 53 重试。每次最多 2 秒，每类记录总计最多 8 秒，
网络收发均为异步；全部失败保留系统结果。成功结果按地址及 CNAME 链的最短 TTL 缓存，
日志只记录发生替换的域名。
关闭任务时可复用尚未过期的替换缓存；仅查缓存的请求不会发起公共 DNS 查询。

离线协议测试首先通过 `--test-dns` 验证报文、TTL、普通网络不重查及回环 UDP / TCP。
真实 fake-ip 环境可运行以下隔离测试（需要公网）：

```sh
python3 -I scripts/test-torrentd-fakeip.py build/thirdparty/bin/mulee-torrentd-before-fakeip --expect blocked
python3 -I scripts/test-torrentd-fakeip.py
```

测试用 curl 获取 Debian 官方种子，使用 `build/` 下全新的临时状态和下载目录，启用 DHT，
最多等待 90 秒；观察到 peer 和下载字节后立即删除任务、停止测试进程并清理临时目录。
下载限速为 1 MiB/s，不读取应用状态或实际下载目录。输出包含 peer 来源、IP / 传输类型、tracker 和磁盘诊断，并核对 DHT 保存与重启回读。

### BT 内核参数、命令和诊断

分享率策略仅对有元数据、所选文件已完成且处于 `seeding` / `finished` 状态的任务执行。
辅助进程用 `torrent_status.is_finished` 上报 `is_finished`，校验中或错误状态不算完成；
Swift 再核对所选大小、已下载量和非空选择。选择性下载不要求未选文件完成，恢复任务不依据
历史 `completed_at` 执行策略；私有种子的豁免设置仍保留。

会话设置为 `connections_limit=500`、`file_pool_size=100`、`unchoke_slots_limit=16`，
新建及恢复任务均设置 `set_max_connections(100)`。`active_limit=max(32, downloads+seeds)`
保留 `dont_count_slow_torrents=true`；`announce_to_all_tiers=true`、
`announce_to_all_trackers=false` 扩展各 tier 的发现范围，并保留同 tier 内的故障切换。
不调整 mixed mode、请求队列、发送缓冲和磁盘线程数。

`configure` 新增两个可选字段，旧调用方不传时采用默认值：

- `disk_cache_bytes`：默认 16 MiB，非负整数限制到 1–256 MiB，映射至
  `max_queued_disk_bytes`。这是待写入队列上限，libtorrent 2.0 的读缓存仍由操作系统管理。
- `blocked_clients`：默认 `[]` 关闭；最多 50 条、每条 1–64 字节可打印 ASCII。
  以 `-` 开头的规则匹配 peer ID 前缀（区分大小写，版本不限），其他规则匹配客户端名称
  前缀（ASCII 不区分大小写，含扩展握手的 `v` 字段）。libtorrent 的
  `torrent_plugin` / `peer_plugin` 在握手后断开命中的连接，运行时变更也作用于现有连接。

Swift 设置为 `TorrentEngineSettings.diskCacheBytes: Int64` 和 `blockedClients: [String]`。
公开常量 `TorrentEngineSettings.defaultBlockedClients` 仅含 `-XL`，依据
[BEP 20 的客户端标识表](https://www.bittorrent.org/beps/bep_0020.html)中 XL 对应 Xunlei。
这份表只确认客户端身份，不证明个别 peer 的上传行为；未确认的 `-SD` / `-QD` 不加入内置规则。

新增任务命令：

- `set_download_mode {id, sequential_download, first_last_priority}`：完整替换两个开关，默认均关闭。
  前者设置 `torrent_flags::sequential_download`；后者为每个所选、非空、非 padding 文件的
  首尾 piece 设置 deadline，不提升未选文件优先级。关闭时撤销自己设置的 deadline；
  元数据到达、文件选择变化及恢复后重新应用。开关保存在任务 metadata，list 可读回。
  Swift API：`setDownloadMode(_:sequentialDownload:firstLastPriority:)`。
- `add_trackers {id, urls:[...]}`：仅接受 HTTP / HTTPS / UDP URL，先完整校验再去重追加；
  每批放入独立且未占用的 tier，任务 tracker 总数上限 50，返回 `{added,total}`，resume 保存后恢复。
  `metadata_pending` 表示元数据尚未到达、可稍后重试；`private_torrent` 拒绝私有种子；
  `tracker_limit` 表示超过数量限制。重复 `add` 也遵守同样的 tracker 注入限制。
  Swift API：`addTrackers(_:urls:) -> TorrentTrackerAdditionResult`。

`list.torrents[].diagnostics` 以每任务一秒为最短间隔采样，包含：

- `connected_peers`、`peer_sources.{tracker,dht,pex,lsd,incoming}`（只计已完成握手的连接，
  来源位可重叠；resume 或显式 peer 可能没有这些来源位）、`ipv4` / `ipv6`、`tcp` / `utp`。
- `trackers_available` / `trackers_failed` / `trackers_pending` 按 URL 分类：任一 endpoint / hash
  已成功 announce 且无当前错误即为可用，否则有失败记录即为失败，其余为待确认。
  `last_tracker_error` 保留最近一次 tracker 错误，即使后续已恢复成功。
- `disk_backlogged` 根据会话级 session stats 判断：`peer.num_peers_down_disk > 0` 或
  `disk.queued_write_bytes >= max_queued_disk_bytes`。同时上报 `queued_disk_bytes`、
  `disk_blocked_peers`、`disk_queue_limit`；尚无采样时积压为 null。非空写入队列本身不算积压。
- `blocked_clients_count` 为当前辅助进程会话内该任务被规则断开的连接数，每连接最多计一次。

Swift 的 `TorrentdTask` 解析这些数据，公开 BT 详情 `TorrentTaskInfo` 包含
`diagnostics: TorrentDiagnostics?`、完成状态及两个下载模式开关，由 `taskInfo(_:)` 读取。

DHT 使用 `session_params` 和仅 `save_dht_state` 标志保存到状态目录的 `dht.state`，不保存会话
设置或其他插件状态。启动先加载，再构造 session；损坏、过大或格式错误的文件记录日志并忽略。
关闭 DHT 时缓存最后的路由快照，避免退出时写入空表。退出只复制本地路由表并原子保存，不等待
网络应答；原有 resume 刷盘确认和 Swift 收到 `saved` 后约 1.2 秒的网络回收期限保持不变。

```sh
scripts/build-torrentd.sh --standalone
python3 -I scripts/test-torrentd.py
MULEE_TORRENTD="$PWD/build/thirdparty/bin/mulee-torrentd" \
  swift test --package-path Packages/MuleeCore --scratch-path build/torrentd-core-tests
python3 -I scripts/test-torrentd-fakeip.py --timeout 90
```

Xcode 构建在 aria2 阶段之后运行 “Bundle mulee-torrentd”，将二进制放入
`Contents/Helpers/mulee-torrentd`，用 Xcode 的签名身份和 hardened runtime 签名，
并在增量构建封印失效时重签 App。保持此二进制名，代理软件按进程名配置的直连规则才会生效。

OpenSSL、libtorrent 和 Boost.JSON 均静态编入辅助进程，`otool -L` 校验只允许 `/usr/lib/`
和 `/System/` 的系统库，运行机器无需 Homebrew。架构固定 arm64，所有源码均指定最低 macOS 26.0，
避免构建机 Homebrew 二进制的最低系统版本漂移。Boost.JSON 的实现只在一个编译单元中引入，
不链接 Boost 动态库。磁盘 I/O 保留 libtorrent 2.0 默认 mmap 后端。

打包时许可证按现有 `Licenses/<库名>/` 风格收集：

| 组件 | 许可证 | 包内文本 |
|---|---|---|
| libtorrent-rasterbar 2.0.15 | BSD-3-Clause | `Licenses/libtorrent/COPYING` |
| OpenSSL 3.5.9 | Apache-2.0 | `Licenses/openssl/LICENSE.txt` |
| Boost | BSL-1.0 | `Licenses/boost/LICENSE_1_0.txt` |

Homebrew Boost 未附带顶层许可证时，脚本从 libtorrent 的聚合 `LICENSE` 提取完整且未改动的
BSL-1.0 文本。`Licenses/README.txt` 追加对应组件和源码地址。

## 电驴引擎 amuled

`Mulee` 的 post-build 阶段 `Bundle amuled` 运行 `scripts/build-amuled.sh`，从已固定的 aMule 3.1.0、wxWidgets 3.2.12、Crypto++ 8.9.0 子模块编译 `Contents/Helpers/amuled`。必须保留进程名 **amuled**，供用户的代理规则匹配直连。App 不打包测试客户端 amulecmd。

构建机需要 Apple Silicon、支持 macOS 26 SDK 的 Xcode / Command Line Tools、`cmake` 和 `/opt/homebrew/opt/boost` 的头文件（`brew install cmake boost`）。缓存未命中时，所需源码由主控预先初始化；编译 wxWidgets 时还需要 PCRE2 / Expat 嵌套子模块。脚本不会初始化、修改子模块，也不会下载构建依赖。所有子进程使用 `LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8`。

```sh
# 构建引擎和测试专用客户端；无需 Xcode 构建环境变量
scripts/build-amuled.sh --standalone
scripts/test-amuled.sh                    # 内部使用 python3 -I，仅标准库
```

缓存默认在 `${MULEE_THIRDPARTY_CACHE:-$SRCROOT/build/thirdparty}`；可用 `BUILD_JOBS` 控制并行度（默认 8）。wxWidgets、Crypto++ 分别按源码提交、编译参数及工具链缓存；aMule 的键额外包含全部子模块键、Boost 版本头、构建脚本内容和是否构建 amulecmd。精确提交用只读 `git archive` 导出到缓存副本；构建过程不会污染 `ThirdParty/`。`<cache>/bin/amuled` 是最近一次成功构建的 daemon，standalone 同时输出 `<cache>/bin/amulecmd`。首次要编译三套 C++ 源码，本机 8 并行约 3–4 分钟（随机器和 SDK 变化）；已有完整 standalone 缓存时只做校验和原子复制。App 阶段另做签名及许可证打包。

### 静态链接与关闭的功能

- wxWidgets 使用 `--disable-gui --disable-shared --enable-unicode`，只构建 base、net 及 wx-config 要求的内置 PCRE2 / Expat 静态归档，不构建 wx XML 或其他 wx 库。PCRE2 为内置 10.37。zlib 固定为 SDK 的系统库。wxWebRequest 使用系统 NSURLSession，关闭 libcurl backend、liblzma 及 GUI 图像库。
- Crypto++ 使用静态归档，aMule 使用 CMake / Release / C++17，全部为 arm64、最低 macOS 26.0。Boost 只使用头文件，不引入 Boost dylib。
- `ENABLE_UPNP=OFF`：端口映射以后由 Mulee 管理，不引入 libupnp。关闭 NLS、IP2COUNTRY、BFD、版本检查、所有 GUI、WebServer / REST API、附属工具及上游测试；本地 UI、更新和产品控制由 Mulee 承担。只有 standalone 开启 amulecmd。
- 静态链接用于固定慢变引擎版本，避免 Homebrew 动态库和运行机环境差异；系统库仍动态链接。脚本强制校验 `otool -L` 仅出现 `/usr/lib`、`/System`，架构仅 arm64，`LC_BUILD_VERSION minos` 必须是 `26.0`。

wx 3.2.12 的 base-only configure 未传入 macOS 平台宏，脚本显式补 `__WXMAC__` / `__WXOSX__`，并给 Objective-C++ 编译传入 SDK 和 AppKit 头；链接系统 AppKit 供 base 工具函数使用，不开启 wx GUI，也不修改上游源码。

签名身份与 aria2 一致，使用 `EXPANDED_CODE_SIGN_IDENTITY`；空值或 `-` 为 ad-hoc，否则同公司证书加 `--timestamp`。helper 一律 `--options runtime`。spike 的 entitlement 是 `com.apple.security.cs.disable-library-validation`，用于无 Team ID 的 ad-hoc 程序加载非系统 dylib；本静态 helper 只加载系统库，**无需此 entitlement**。可执行文件通过临时副本加原子替换更新，避免覆盖运行中的签名代码页触发 `CODESIGNING Invalid Page`。增量构建若 App 原有资源封印失效，脚本保留 App 的 entitlements / flags 重签，随后仍由 Xcode 最终签名。许可证放入独立的 `Licenses/amule`、`wxWidgets`、`cryptopp`、`pcre2`、`expat`、`picojson`；Boost 使用共用的 `Licenses/boost/LICENSE_1_0.txt`，不删除其他引擎的许可证。

### 最小可用 amule.conf

以下键名以 3.1.0 的 `src/Preferences.cpp` 为准，也是离线测试实际生成的配置。所有 `<...>` 占位符都需替换；端口用各自空闲的随机端口，目录先创建，配置文件权限设为 `0600`。ECPassword 是 UTF-8 密码的 **32 位十六进制 MD5**，不是明文。

```ini
[eMule]
Nick=Mulee-EC-Test
Address=127.0.0.1
Port=<peer TCP port>
UDPPort=<Kad UDP port>
UDPEnable=0
Autoconnect=0
Reconnect=0
ConnectToED2K=0
ConnectToKad=0
UPnPEnabled=0
Serverlist=0
AddServerListFromServer=0
AddServerListFromClient=0
IncomingDir=<absolute temporary Incoming path>
TempDir=<absolute temporary Temp path>
ShareHiddenFiles=0
AutoRescanSharedDirs=0
[ExternalConnect]
AcceptExternalConnections=1
ECAddress=127.0.0.1
ECPort=<EC TCP port>
ECPassword=<MD5 of random password>
[WebServer]
Enabled=0
[AmuleApi]
Enabled=0
[MediaMetadata]
Enabled=0
```

使用独立 `--config-dir`，不传 `--fork`；启动和 amulecmd 都设置 UTF-8 locale。配置目录内的 `shareddir.dat`、`shareddir-explicit.dat`、`shareddir-recursive.dat` 为空，不读取用户共享目录。Incoming 是空临时目录；aMule 固有行为仍会把 Incoming 和未完成任务的可用数据作为共享候选，不能将它理解成运行时彻底禁用上传。

**中文路径的特殊编码**：`Cfg_Path` 通过 `CPath::FromUniv/ToUniv` 保存文件名字节。将路径的 UTF-8 字节逐字节映射到 Latin-1 码点，再把得到的字符串以 UTF-8 写进配置；不要直接写普通中文路径。Python 等价表达为 `os.fsencode(path).decode("latin-1")`。测试程序按此处理。ECAddress、Address 则是普通字符串。

这份配置刻意关闭两种 P2P 网络，保证自动测试离线。产品启用网络时需把 peer `Address` 改为空（监听网络接口），开启 `UDPEnable`、`ConnectToED2K`、`ConnectToKad`、`Autoconnect` / `Reconnect`；**ECAddress 继续保持 127.0.0.1**。测试使用虚构名称 `Mulee-Fictional-EC-Test.bin` 和虚构 hash，不查找真实作品。

自动测试覆盖：EC 端口就绪、认证 status、添加 ed2k、show dl、错误密码拒绝、SIGTERM 正常退出、重启后任务持久化及进程清理。失败时输出 daemon 日志，并在 finally 终止和回收本次启动的进程；临时配置和任务文件自动删除。

### 本次验证记录（2026-10-15）

构建 / 运行主机为 macOS 27.0.1、arm64，SDK 27.0；产物的部署目标经 `vtool` 实测是 26.0，尚未在 macOS 26 实机运行。amuled 为 6,392,032 字节，`otool -L` 只有系统路径，签名是 `adhoc,runtime`，无 helper entitlements。standalone 和 App 内 helper 均通过离线 EC / 持久化 / 退出测试。Xcode 构建、增量构建及最终 `codesign --verify --deep --strict` 均通过；增量日志确认最后的 amuled 阶段实际重签了 App。Developer ID 和公证未实测。

真实网络冒烟与自动测试分开，使用 `.org` 的 HTTPS 引导地址：`https://upd.emule-security.org/server.met`（2,577 字节）、`https://upd.emule-security.org/nodes.dat`（5,860 字节）。2026-10-15 21:01:50–21:04:50（UTC+8）观察 180.1 秒：约 3 秒连接 ed2k-rust `85.17.116.222:6082`，为预期的 **Low ID**；Kad 同时达到 **Connected (firewalled)**。21:03:53 服务器连接丢失，21:03:55 自动重连，最终仍为 Low ID；不能把定时 status 均为 Connected 理解成全程没有断线。没有添加网络下载任务。结束后 SIGTERM 返回 0，配置、引导文件和临时目录已删除，无残留 amuled。

首次冒烟曾因并行构建原地覆盖缓存可执行文件而被 macOS 以 `CODESIGNING Invalid Page` 终止；修复为原子替换后完成上述整轮测试，期间再次更新缓存及增量构建，进程正常存活。增量封印检查也避免使用 `grep -q`：它提前关闭输出管道时，在 `pipefail` 下会令 codesign 返回 141，跳过重签；改为完整消费输出。

本次验证工程及所有编译产物放在 `build/` 中，未改动正式工程生成物或子模块。验收日志：`build/amuled-build.log`、`amuled-xcode-build.log`、`amuled-xcode-incremental.log`、`amuled-test.log`、`amuled-app-test.log`、`amuled-verification.log`、`amuled-network-smoke.log`、`amuled-network-daemon.log`（以上日志除第一个完整路径外均相对 `build/`）。

## 视频工具

Mulee 自行下载并校验 yt-dlp、Deno、ffmpeg 和 ffprobe，安装在 `~/Library/Application Support/Mulee/bin/`。ffmpeg 与 ffprobe 放在同一目录；传入 YtDlpEngine 的是 ffmpeg 文件路径，yt-dlp 的 `--ffmpeg-location` 会据此查找同目录的 ffprobe，HEVC 后处理也可直接执行该路径。解析顺序为已校验的托管版、仅 Debug 可用的 Homebrew、后台下载托管版。不会在下载尚未结束时显示缺少 ffmpeg。

托管的 ffmpeg 是静态编译版，自己读不到系统钥匙串里的根证书。指定时间段下载（`--download-sections`）时由 ffmpeg 直接拉流，所以启动 yt-dlp 子进程时默认设置 `SSL_CERT_FILE=/etc/ssl/cert.pem`（调用方已设置时不覆盖），否则 HTTPS 会报 `certificate verify failed`。

### arm64 来源比较

2026-10-15 在 Apple Silicon macOS 上下载实测：

| 来源 | 架构、签名与公证 | 下载与 SHA256 | 许可证及更新 |
|---|---|---|---|
| [Martin Riedl](https://ffmpeg.martin-riedl.de/)（选用） | ffmpeg、ffprobe ZIP 内均为原生 arm64，Developer ID Application 签名；PKG 为 Developer ID Installer 签名且通过公证评估。ZIP 内命令行程序的 execute 评估未被接受，不能把 PKG 公证结论套用到 ZIP | 官方提供稳定 latest 重定向及每个构建的 `.zip.sha256`；实测 latest 的 `.zip.sha256` 地址返回 HTTP 404，因此固定版本和摘要 | `-L` 实测 GPL-3.0-or-later，`-version` 有 `--enable-gpl --enable-version3`；有[公开构建脚本](https://git.martin-riedl.de/ffmpeg/build-script)和[发布历史](https://ffmpeg.martin-riedl.de/info/history/macos/arm64/release)。当前 release 9.0.2 构建于 2026-09-20，snapshot 更新至 2026-10-10；不保证固定更新周期 |
| [OSXExperts](https://www.osxexperts.net/) | 9.0 ffmpeg、ffprobe 实测原生 arm64，只有 linker ad-hoc 签名，未设 Team ID；execute 评估均 rejected，没有 Developer ID 或通过公证的证据 | `ffmpeg9arm.zip`、`ffprobe9arm.zip` 按大版本命名，页面公布的是解压后可执行文件 SHA256；没有找到跨版本 latest 地址或独立 SHA256 文件 | `-L` 实测 GPL-2.0-or-later；页面保留多个大版本，当前 arm64 9.0，未找到固定更新周期承诺 |
| [evermeet.cx](https://evermeet.cx/ffmpeg/) | 9.0.2 ffmpeg 实测 x86_64、完全未签名，execute rejected / no usable signature；[官网明确不提供 Apple Silicon 原生构建](https://evermeet.cx/ffmpeg/#remarks)，不适用本项目 | 有版本 ZIP/7z 和 GPG 签名；官网说明下载 API 已移除，Info API 可发现版本，未找到适用 arm64 的 latest + SHA256 文件 | 官网构建参数为 GPL 构建（包含 `--enable-gpl --enable-version3`）；有 release 与 snapshot 更新，仍不满足 arm64 要求 |

### 固定版本与校验

固定 Riedl `1789931890_9.0.2`，不跟随 latest 漂移：

| 文件 | 上游 SHA256 文件 | 代码内固定的压缩包 SHA256 |
|---|---|---|
| ffmpeg.zip | [ffmpeg.zip.sha256](https://ffmpeg.martin-riedl.de/download/macos/arm64/1789931890_9.0.2/ffmpeg.zip.sha256) | `c8ed4c4e6978a03c485edbfe4e0a5dc2380f8a30bba5150531b31b094492d924` |
| ffprobe.zip | [ffprobe.zip.sha256](https://ffmpeg.martin-riedl.de/download/macos/arm64/1789931890_9.0.2/ffprobe.zip.sha256) | `fcbe839537485eaee7a7a8bc5cbc0f90d53617e80943e8a5b2e31cb851197ea6` |

`ManagedTool` 内固定下载目录和两份摘要。安装器先验证整个 ZIP 的 SHA256，只提取指定入口，再执行 `-version`；已安装文件另以本机安装记录的 SHA256 复核。更新时从发布历史选择新的固定构建，下载两份 ZIP 和对应校验文件，核对摘要、架构、签名、许可证与运行结果，再同时更新代码及本节；不能只修改下载 URL。

签名与公证实测摘要（未安装 PKG，未进行重新签名）：

```text
file ffmpeg / ffprobe
  Mach-O 64-bit executable arm64
codesign -dv --verbose=4 ffmpeg / ffprobe
  Authority=Developer ID Application: Martin Riedl (KU3N25YGLU)
  TeamIdentifier=KU3N25YGLU
  flags=0x10000(runtime)
spctl -a -t execute -vv ffmpeg / ffprobe
  rejected (the code is valid but does not seem to be an app), exit 3
spctl -a -t install -vv ffmpeg.pkg
  accepted, source=Notarized Developer ID, exit 0
  origin=Developer ID Installer: Martin Riedl (KU3N25YGLU)
ffmpeg -version / ffprobe -version
  9.0.2-https://www.martin-riedl.de, exit 0
```

Riedl 静态构建的 `otool -L` 实测只引用系统库及系统 Framework，不依赖 Homebrew。Mulee 使用 ZIP，不运行系统级 PKG 安装；沿用安装器在 SHA256 验证后移除隔离属性的流程，保留上游签名。安装记录中的摘要用于检测本机文件损坏，信任锚是代码内固定的上游 ZIP 摘要。

2026-10-15 另使用 MuleeCore 的 `ManagedToolInstaller` 默认网络下载器，在临时目录完成两份工具的真实下载、固定 SHA256 校验、解包、安装记录回读及 `-version` 运行；两者均退出 0。对安装结果执行 `codesign --verify --strict --verbose=2` 均返回 `valid on disk` 和 `satisfies its Designated Requirement`。本地 fixture 测试不访问网络；核心包 107 项、App 142 项测试通过，无新增 Swift 编译警告。

### 首次准备与退出恢复

添加视频链接时立刻插入排队任务，副标题显示「正在准备视频工具」，就绪后再交给引擎。等待时删除不会再提交；暂停则保留至用户继续。准备失败会把等待任务标记为失败并显示原因。等待记录沿用现有任务历史保存，重启后标记为「上次退出时视频工具尚未准备好，可以重新下载」；选择明确失败而不自动重交，是因为尚未交给引擎的记录没有可靠的自定义保存目录，不能静默改用默认目录。

## App 自动更新（Sparkle 2）

SwiftPM 精确固定 Sparkle **2.10.0**（MIT），许可证及上游附带声明在
`Contents/Resources/Licenses/sparkle/LICENSE`。包自带的 XPC 服务、Autoupdate、
Updater.app 在 Xcode 的 `Sign Sparkle components` 阶段从内到外以当前身份重签，
保留上游 entitlements，启用 hardened runtime；非 ad-hoc 身份附带安全时间戳。
发版脚本检查包内每个 Mach-O 的 Developer ID、时间戳、runtime 与调试权限，
并执行 `codesign --verify --deep --strict`。

正式构建默认每日自动检查，用户的两个更新开关直接使用 Sparkle 偏好，不写 SettingsModel。
Debug 启动不启动 updater，手动检查后也拒绝后台检查；单元测试宿主拒绝全部更新检查。
安装时如有正在进行的任务会要求确认；确认后等待引擎退出并保存任务历史，再交回 Sparkle。
自动下载的更新在退出时安装，也使用相同确认及保存流程，保存失败则不允许退出安装。
不发送系统信息。生产 feed 固定为：
`https://github.com/cqagc/mulee/releases/latest/download/appcast.xml`。

### 首次配置生产公钥（由主控执行）

当前 `project.yml` 中的 `SUPublicEDKey` 是占位值，发版前必须替换。
先解析 SwiftPM 依赖，再执行以下命令；私钥由 Sparkle 存入登录钥匙串，工人不生成、读取或导出生产私钥：

```sh
SPARKLE_BIN="$(dirname "$(find build/dd/SourcePackages/artifacts/sparkle -type f -path '*/bin/generate_keys' -print -quit)")"
"$SPARKLE_BIN/generate_keys"
export MULEE_SPARKLE_PUBLIC_KEY="$("$SPARKLE_BIN/generate_keys" -p)"
python3 - <<'PY'
import base64
import os
import pathlib

key = os.environ["MULEE_SPARKLE_PUBLIC_KEY"].strip()
assert len(base64.b64decode(key, validate=True)) == 32
path = pathlib.Path("project.yml")
text = path.read_text()
placeholder = "SUPublicEDKey: REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY"
assert placeholder in text, "占位值已被替换，请人工核对现有公钥"
path.write_text(text.replace(placeholder, f'SUPublicEDKey: "{key}"'))
PY
unset MULEE_SPARKLE_PUBLIC_KEY
```

`generate_keys -x` 会导出钥匙串私钥、`-f` 会导入钥匙串，不能用于不写钥匙串的隔离测试。
测试夹具应以 CryptoKit 生成一次性 Ed25519 seed / public key 文件，`sign_update --ed-key-file`
读取测试 seed，结束删除密钥与临时 bundle；不把测试公钥填入正式 `project.yml`。

### 发版与附件

1. 主控更新 `MARKETING_VERSION` 与递增的 `CURRENT_PROJECT_VERSION`，确认生产公钥已填写。
2. 设置 Developer ID 与公证凭据后运行 `scripts/release.sh`。仍按 Release 构建、签名、
   App 公证装订、DMG 签名、公证装订的顺序执行。
3. 脚本从本次 DerivedData 的 `SourcePackages/artifacts/sparkle/…/bin/sign_update`
   定位 Sparkle 工具，对装订后的最终 DMG 字节生成 EdDSA 签名及 `build/release/appcast.xml`。
   默认读取 Sparkle 钥匙串私钥，也可设置 `MULEE_SPARKLE_KEY_FILE=/安全路径/私钥文件`。
   没有可用私钥时提示并跳过 appcast；已有密钥但签名失败时中止。未公证装订也不生成 appcast。
4. 发版说明定稿后运行 `scripts/appcast-notes.py build/release/appcast.xml <notes.md>`，
   再运行 `python3 -I scripts/privacy-check.py --file build/release/appcast.xml` 检查最终 appcast。
5. 主控将 `Mulee-<版本>.dmg`、对应 `.sha256`、`appcast.xml` 一起上传到对应的
   `v<版本>` GitHub Release，并把它设为最新正式版。脚本只生成本地产物，不上传。
   缺少 appcast 的 Release 不应设为 latest，否则固定 feed 会返回 404。

appcast 下载地址是 `https://github.com/cqagc/mulee/releases/download/v<版本>/Mulee-<版本>.dmg`，
`sparkle:version` 来自构建号，`sparkle:shortVersionString` 来自版本号，最低系统为 26.0，
发布说明以本地化 HTML 内嵌在 `description`（英文默认、`zh-Hans` 简体中文）中，
`sparkle:fullReleaseNotesLink` 指向 `https://github.com/cqagc/mulee/releases`，用于版本历史按钮。

### 本地发现更新验证

`MuleeTests/AppUpdate*` 覆盖设置绑定、自动检查限制、安装确认与等待保存。
`AppUpdateDiscoveryTests` 仅在传入 `MULEE_APP_UPDATE_TEST_BUNDLE` 时启用：该路径是一个
临时 `.app` bundle，Info.plist 使用临时公钥、低构建号、关闭自动检查，并指向本机 HTTP appcast；
appcast 的新版本构建号为 `999999`，附上由测试私钥签出的 enclosure。通过
`TEST_RUNNER_MULEE_APP_UPDATE_TEST_BUNDLE` 把路径传给 xcodebuild 的测试宿主。
探针调用 Sparkle `checkForUpdateInformation()`，断言 XML 已解析且发现新版本，不下载、不替换应用。
启动任何 Mulee 实例或测试宿主前先 `mkdir /tmp/mulee-e2e.lock`；失败每 20 秒重试，
最多 40 分钟。持锁后确认 `pgrep -x Mulee` 为空；结束仅按 PID 退出自己的实例并 `rmdir` 释放锁。

2026-10-16 本 worktree 验收：App 197 项测试整体通过（既有 `systemProbe` 跳过），
新增 8 项更新测试均运行通过；本机 HTTP appcast 返回 200，Sparkle 实际解析并发现构建号
999999，未请求更新压缩包、未安装或替换应用。测试 seed / public key 仅写临时文件，
结束已删除，未操作用户钥匙串；测试宿主正常退出后释放自己的 E2E 锁。
另用同一测试签名验证 `release.sh` 的 appcast 版本、下载 URL、最低系统、发布说明与长度字段。
Debug / Release 构建及 `check-l10n` 均通过；Release 包 11 个 Mach-O 全部通过公司
Developer ID、时间戳、runtime、团队与无调试权限检查，深度严格签名验证通过，许可证回读一致。
新增代码没有编译警告；Release 仍报告 `MuleeApp.swift` 未改动的四处示例数据不可达分支，
Xcode 仍报告无 AppIntents.framework 的元数据抽取警告。本次未公证、未发版、未上传。
验证工程、缓存副本及日志位于 `build/sparkle-verification/`，DerivedData 位于 `build/dd/`。

### 电驴自动端口映射

amuled 自带的 UPnP 仍关闭。Mulee 从已就绪引擎的 EC 连接偏好读取 TCP 和客户端 UDP 端口；aMule 3.1.0 另有服务器 UDP socket，使用 TCP + 3。客户端 UDP 同时承担 Kad 和客户端扩展协议，EC 控制端口仅监听回环地址，不映射。TCP 超过 65532 时无法按该规则确认服务器 UDP，诊断不会声称映射已就绪。

BT 辅助进程接收 `set_extra_port_mappings {tcp:[...],udp:[...]}`，完整替换期望端口集合，重复请求幂等，空数组撤销。仅在 `port_mapping` 开启时向 libtorrent 申请。设置关闭会撤销句柄并保留期望集合；重新开启、监听接口变化或辅助进程重启后重新申请。`portmap` / `portmap_error` 事件及 `session_status.extra_port_mappings` 包含协议、本机端口、外部端口、映射机制和结果。外部端口与本机端口不同时，不能认定电驴已可连入。

适用范围是电脑与家庭路由器在同一网段、路由器支持 UPnP / NAT-PMP。路由器接受映射不代表宽带有公网 IPv4；诊断确认没有公网 IPv4 时，网络页会说明应向宽带运营商申请，停止建议手工转发。未确认时保留原有说明。诊断分别展示路由器是否接受映射与服务器 / Kad 是否确认可连入。三个电驴端口映射就绪后，App 会通过现有 EC 连接命令重新连接尚不可连入的网络，避免重复重连已确认可连入的会话。

```bash
scripts/build-torrentd.sh --standalone
python3 -I scripts/test-torrentd.py
swift test --package-path Packages/MuleeCore --scratch-path build/core-tests
python3 -I scripts/test-ed2k-portmap.py
```

实网脚本仅使用 `build/` 内的临时目录与非默认空闲端口，先记录未映射的服务器 / Kad 状态，再申请三个电驴端口映射并重新连接。它比较 EC Client ID 所表示的地址与路由器公网出口；无法确认直连或地址不一致时报告失败，不调整代理、路由或系统网络。测试退出时正常结束两个子进程，并通过路由器只读接口检查测试映射已撤销，随后删除临时目录。发现阶段无法读取路由器服务时会报告验证受阻，不能把这种情况算成测试通过。

### 宽带公网 IPv4 诊断与隔离验证

网络诊断从物理接口绑定 SSDP 多播（包括 `IP_MULTICAST_IF`），发现 InternetGatewayDevice 后只读取 `GetExternalIPAddress`。仅接受同网段默认网关的私有 IPv4 LOCATION，设备描述中的 URLBase / controlURL 也必须通过相同检查；禁用 HTTP 重定向、系统 HTTP 代理、凭据及 cookie 存储。SSDP 响应最多 8 KiB，XML 响应最多 64 KiB，拒绝 DTD、实体声明、过深嵌套和过多节点，不解析外部实体。发现约等待 1.2 秒，每次 HTTP 请求最多 0.7 秒，探测在并发执行器上运行。

WAN 位于私有地址或共享地址范围时显示“运营商没有分配公网 IPv4”；公网地址显示“正常”。发现失败、跨网段、不支持、超时、无效或保留地址、多个服务返回不同地址均保持“未确认”。这项证据只说明路由器报告的 WAN IPv4，不代替 BT 的实际入站连接证据，也不能证明所有上游网络拓扑。没有公网 IPv4 时，设置页与侧边栏说明电驴仍能下载但来源较少，建议申请公网 IPv4；只有 BT 已实际确认可连入时才显示 BT 不受影响。

```bash
# 先构建 Debug App；本模式直接复用 App 的诊断链路，不创建窗口、引擎或用户存储。
python3 -I scripts/test-ed2k-portmap.py --diagnose-only

# 家庭网络使用，当前公司网络不执行此模式。
python3 -I scripts/test-ed2k-portmap.py --mapping-only
```

`--mapping-only` 启动隔离的临时 amuled 和 `build/thirdparty/bin/mulee-torrentd`，即使 WAN 不是公网 IPv4 也申请映射。申请前确认候选端口未被映射；使用 `GetSpecificPortMappingEntry` 核对电驴 TCP、客户端 UDP、服务器 UDP 的内部端口、内部地址和启用状态。撤销后再次查询确认删除；退出时清理 BT 映射、两个子进程及临时目录。此模式不连接电驴服务器或 Kad，不以能否从外部连入作为映射成功的判据，不修改代理规则或路由器管理配置。

## 操作音效来源与重建

`Mulee/Resources/Sounds/` 包含九个 48 kHz、16 位单声道 CAF 音效，峰值为 −12 至 −20 dBFS（点击类更轻）。采用 PCM CAF：资源总量不足 350 KiB，避免有损编码对短促点击的瞬态产生影响，预加载后播放不需要额外解码。

| 音效 | 来源与许可 |
|---|---|
| download_complete、all_complete、failed、pause、resume、delete、link_received、warning | Mulee 用 `scripts/make-ui-sounds.py` 从正弦和噪声合成，无外部采样，按本项目相同的 GPL-3.0 许可发布。 |
| task_added | 由 Stable Audio Open 1.0 生成后裁切、归一化。提示词为 “soft gentle user interface pop with a subtle airy upward swish, clean, minimal, quiet, short sound effect”，种子 68619，生成 2 秒后裁到约 0.14 秒。模型使用 [Stability AI Community License](https://stability.ai/license)，按该许可生成内容的权利归使用者；年收入超过许可门槛的组织商用前需另行确认。 |

合成脚本依赖 Python 3 与 numpy。输出目录由参数指定，八个合成音效的峰值分别为：完成 / 全部完成 −12 dBFS、失败 / 警告 −13 dBFS、暂停 / 继续 −18 dBFS、删除 −20 dBFS、收到链接 −16 dBFS。`task_added` 是固定生成资源（−14 dBFS），脚本会跳过，保留仓库内定稿文件。

```bash
python3 scripts/make-ui-sounds.py /tmp/mulee-ui-sounds
for source in /tmp/mulee-ui-sounds/*.wav; do
  name=$(basename "$source" .wav)
  afconvert -f caff -d LEI16 "$source" "Mulee/Resources/Sounds/$name.caf"
done
```

`general.uiSounds` 默认开启，并遵守系统的「播放用户界面声音效果」。打开「通知声音」后，完成和失败提示由系统通知出声；操作音效不再叠加。相同音效在 150 ms 内去抖；完成事件按连续一秒窗口合并，最后一个完成事件决定播放普通完成还是全部完成。自动暂停 / 继续不播放操作音，磁盘保护和卷断开每次新事件只播放一次警告。启动恢复、引擎重新同步和单元测试宿主不播放提示音。
