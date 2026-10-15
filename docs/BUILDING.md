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

## 视频工具

Mulee 自行下载并校验 yt-dlp、Deno、ffmpeg 和 ffprobe，安装在 `~/Library/Application Support/Mulee/bin/`。ffmpeg 与 ffprobe 放在同一目录；传入 YtDlpEngine 的是 ffmpeg 文件路径，yt-dlp 的 `--ffmpeg-location` 会据此查找同目录的 ffprobe，HEVC 后处理也可直接执行该路径。解析顺序为已校验的托管版、仅 Debug 可用的 Homebrew、后台下载托管版。不会在下载尚未结束时显示缺少 ffmpeg。

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
