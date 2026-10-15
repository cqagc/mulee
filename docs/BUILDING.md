# 构建与打包说明

## 日常构建

```sh
brew install aria2          # 仅构建机需要；运行 Mulee.app 的机器不需要
xcodegen generate
xcodebuild -project Mulee.xcodeproj -scheme Mulee -destination 'platform=macOS' -derivedDataPath build/dd build
```

构建时 `Mulee` target 的 `postBuildScripts` 阶段会运行 `scripts/bundle-aria2.sh`，把 aria2c 打进 App。

## 打包原理

脚本做的事（每次构建都会重新做，可重复运行）：

1. **找来源**：环境变量 `ARIA2C_SOURCE` 指定的 aria2c，否则 `$(brew --prefix aria2)/bin/aria2c`。找不到就构建失败，并提示 `brew install aria2`。
2. **拷贝并改写**：
   - aria2c → `Mulee.app/Contents/Helpers/aria2c`（引擎优先查找这个位置，见 `Aria2BinaryLocator`）。
   - 递归收集所有非系统 dylib（`/usr/lib`、`/System` 之外，含间接依赖，解析 `@rpath` / `@loader_path`）→ `Contents/Frameworks/aria2/`。当前是 sqlite、openssl@4（libssl、libcrypto）、libssh2、c-ares、gettext（libintl）。
   - OpenSSL 的 provider 模块 `ossl-modules/legacy.dylib` → `Contents/Frameworks/aria2/ossl-modules/`。
   - CA 证书包（Homebrew `ca-certificates` 的 `cacert.pem`，可用 `ARIA2_CA_BUNDLE` 覆盖）→ `Contents/Resources/aria2/cert.pem`。
   - 用 `install_name_tool` 把 dylib 的 ID 和引用改成 `@executable_path/../Frameworks/aria2/<名字>`（dylib 之间用 `@loader_path`），并删掉指向 `/opt/homebrew` 的 rpath。最后脚本会检查没有任何残留的非系统绝对路径引用。
3. **签名**：见下。
4. **许可证**：见下。

脚本关闭了 Mulee target 的 `ENABLE_USER_SCRIPT_SANDBOXING`：它要读 `/opt/homebrew`，而且间接依赖事先不可知，没法逐个声明为输入文件。阶段设了 `basedOnDependencyAnalysis: false`，每次构建都运行。

## 引擎必须遵守的两处约定

Homebrew 的 libcrypto 把 `MODULESDIR`、`OPENSSLDIR` 写死成 `/opt/homebrew/...`。在没有 Homebrew 的机器上，不做下面两件事 aria2c 起不来 / HTTPS 校验不过：

| 约定 | 值 |
|---|---|
| 环境变量 `OPENSSL_MODULES` | `<App>/Contents/Frameworks/aria2/ossl-modules`（否则启动即报 `OSSL_PROVIDER_load 'legacy' failed`） |
| aria2c 参数 `--ca-certificate` | `<App>/Contents/Resources/aria2/cert.pem`（否则 HTTPS 下载报错） |

这两处在 `Packages/MuleeCore` 的引擎启动 aria2c 时设置（`<App>` 即 `Bundle.main.bundleURL`）。

## 签名方式

- 身份取 Xcode 的 `EXPANDED_CODE_SIGN_IDENTITY`；为空或 `-` 就是 ad-hoc。
- 顺序：先签每个 dylib（含 `ossl-modules`），再签 `Helpers/aria2c`（`--options runtime`），最后由 Xcode 签 App（封印会覆盖 Helpers / Frameworks 下已签好的内容）。
- **ad-hoc（开发构建）**：aria2c 带 `Mulee/Resources/Aria2Helper-adhoc.entitlements`（`com.apple.security.cs.disable-library-validation`）。ad-hoc 没有 Team ID，hardened runtime 下不加这个就加载不了同包 dylib。
- **Developer ID（正式发版）**：所有 Mach-O 用同一个公司证书、`--options runtime --timestamp` 签名，同 Team ID 满足库验证，**不要**带上面那个 entitlements，也不需要别的 entitlements。公证（notarytool）前要保证包里没有未签名的 Mach-O。
- 增量构建时 Xcode 认为 App 没变，不会重新签名；脚本末尾会检查 `codesign --verify --deep --strict`，封印失效就自己重签 App（保留 entitlements 和 flags）。

验证：

```sh
codesign --verify --deep --strict --verbose=2 build/dd/Build/Products/Debug/Mulee.app
```

## 许可证义务

打包即再分发，必须随 App 附带许可证。脚本把许可证文本拷到 `Contents/Resources/Licenses/<库名>/`，并生成 `Licenses/README.txt`（库名、版本、许可证、源码地址）。

| 组件 | 许可证 | 备注 |
|---|---|---|
| aria2 | GPL-2.0-or-later，附 OpenSSL 链接例外（`LICENSE.OpenSSL`） | Mulee 本身是 GPL-3.0，兼容；需提供对应源码（README 里给了 aria2 源码地址） |
| openssl@4 | Apache-2.0 | |
| libssh2 | BSD-3-Clause | |
| c-ares | MIT | |
| sqlite | 公共领域（Homebrew 标 `blessing`） | 没有许可证文件，构建日志会给 warning，属预期 |
| gettext（libintl） | LGPL-2.1-or-later（Homebrew 标 `GPL-3.0-or-later AND LGPL-2.1-or-later`） | Cellar 里只有 `COPYING`（GPL 文本）；实际链接的是 libintl 库部分，按 LGPL 处理。正式发版前请复核，并提供源码获取方式 |
| Mozilla CA 证书包（cert.pem） | MPL-2.0 | 脚本生成 `Licenses/ca-certificates/NOTICE.txt`，指向 MPL 文本和数据来源 |

找不到许可证文件的库，脚本会输出 `warning:`，不会静默。

## 已知限制

- **构建机依赖 Homebrew**：没装 aria2（或 ca-certificates）构建会失败；运行方不需要。
- **最低系统版本**：打包的是 Homebrew 在构建机上编译的二进制，它们的 `minos` 取决于当时的 macOS。2026-10-15 在 macOS 27 上实测：aria2c、libssl、libcrypto、libssh2、libcares、`legacy.dylib` 为 `minos 27.0`，libintl、libsqlite3 为 `minos 26.0`。App 的部署目标是 macOS 26，**在 macOS 26 上这些 minos 27.0 的二进制会无法加载**。发版前需要在 macOS 26 构建机上打包，或自己用 `MACOSX_DEPLOYMENT_TARGET=26.0` 编译 aria2 及依赖，再用 `ARIA2C_SOURCE` 指向它。可用 `vtool -show-build <文件>` 检查。
- **版本随 Homebrew 漂移**：包里是构建时 Homebrew 的版本，升级后 dylib 文件名（如 `libsqlite3.3.53.4.dylib`）会变，脚本会自动处理。
- **只有 arm64**：和 App 一致，不做 universal。
- **体积**：约增加 11 MB（aria2c 约 3 MB、dylib 约 7.5 MB、证书和许可证约 0.3 MB）。
- 构建机上的 aria2 / openssl 若带有额外的 provider 模块，目前只打包 `ossl-modules` 下已有的文件。

## BT 辅助进程 mulee-torrentd

构建机需要 Xcode 命令行工具，以及 `brew install cmake boost`。先初始化固定版本的源码子模块：

```sh
git submodule update --init --recursive
scripts/build-torrentd.sh --standalone
python3 -I scripts/test-torrentd.py
```

脚本在源码副本中编译 OpenSSL 3.5.9，再编译 libtorrent-rasterbar 2.0.15，最后用 C++17
编译 `Helpers/mulee-torrentd/`。不会修改 `ThirdParty/`。首次全量编译约 8 分钟；
静态依赖缓存在 `${MULEE_THIRDPARTY_CACHE:-$SRCROOT/build/thirdparty}/<缓存键>/`，
缓存键包含两个子模块提交号、编译参数、Boost 版本和工具链信息，命中后跳过依赖编译。
`--standalone` 只产出 `<cache>/bin/mulee-torrentd`，可供命令行及 MuleeCore 集成测试使用：

```sh
build/thirdparty/bin/mulee-torrentd --state-dir "$PWD/build/torrent-state"
```

进程通过 stdin/stdout 的 JSON Lines 通信，协议见 `docs/TORRENTD-PROTOCOL.md`。
关闭 stdin 或发送 `shutdown` 会保存 resume data 并退出。构建及辅助进程的子进程环境使用
`LANG=en_US.UTF-8`、`LC_ALL=en_US.UTF-8`。自动测试只使用临时生成的数据和本机回环互传，
不依赖公网或第三方 tracker。

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

`Mulee` 的最后一个 post-build 阶段 `Bundle amuled` 运行 `scripts/build-amuled.sh`，从已固定的 aMule 3.1.0、wxWidgets 3.2.12、Crypto++ 8.9.0 子模块编译 `Contents/Helpers/amuled`。必须保留进程名 **amuled**，供用户的代理规则匹配直连。App 不打包测试客户端 amulecmd。

构建机需要 Apple Silicon、支持 macOS 26 SDK 的 Xcode / Command Line Tools、`cmake` 和 `/opt/homebrew/opt/boost` 的头文件（`brew install cmake boost`）。源码需由主控预先递归初始化，包含 wxWidgets 的 PCRE2 / Expat 嵌套子模块。脚本不会初始化、修改子模块，也不会下载构建依赖。所有子进程使用 `LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8`。

```sh
# 构建引擎和测试专用客户端；无需 Xcode 构建环境变量
scripts/build-amuled.sh --standalone
scripts/test-amuled.sh                    # 内部使用 python3 -I，仅标准库
```

缓存默认在 `${MULEE_THIRDPARTY_CACHE:-$SRCROOT/build/thirdparty}`；可用 `BUILD_JOBS` 控制并行度（默认 8）。wxWidgets、Crypto++ 分别按源码提交、编译参数及工具链缓存；aMule 的键额外包含全部子模块键、Boost 版本头、构建脚本内容和是否构建 amulecmd。精确提交用只读 `git archive` 导出到缓存副本；构建过程不会污染 `ThirdParty/`。`<cache>/bin/amuled` 是最近一次成功构建的 daemon，standalone 同时输出 `<cache>/bin/amulecmd`。首次要编译三套 C++ 源码，本机 8 并行约 3–4 分钟（随机器和 SDK 变化）；本次 standalone 缓存命中为 0.41 秒，只做校验和原子复制。App 阶段另做签名及许可证打包。

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
