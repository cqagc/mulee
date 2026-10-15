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
