# 浏览器扩展入口

扩展通过系统打开以下 URL（每个参数值单独用 `encodeURIComponent` 编码）：

```
mulee://add?url=<下载链接>&url=<另一个下载链接>&referrer=<来源页面地址>&text=<选中文字>
```

- 只支持 `add`，不支持路径、账号、端口或片段。
- `url` 可重复，必须有至少一条下载链接；支持 LinkParser 识别的 magnet、ed2k、thunder、HTTP、HTTPS、FTP、视频页面和远程 .torrent。
- 一次最多 200 个 url 参数，解析出的链接也不能超过 200 条。整个编码后入口 URL 最多 1,048,576 个 UTF-8 字节，超限拒绝整次请求。
- `file://`、本地绝对路径、相对路径和 thunder 内包裹的本地种子一律拒绝；即使与有效链接混合也拒绝。入口不会读取网页指定的本地文件。
- `referrer` 可选，只接收 HTTP/HTTPS 页面地址，随确认后的任务保存为 `sourcePageURL`。自动解压的「来源网站」规则优先匹配该地址，旧任务继续匹配下载链接。
- `text` 可选。启用「从下载页面的文字里识别解压密码」时，识别「解压密码：xxx」「密码: xxx」「password: xxx」，支持全角冒号和英文大小写。密码随草稿保存在内存，解压期间临时使用钥匙串，完成后移除；不写进 tasks.json。
- 所有有效请求只激活或创建主窗口并预填「新建下载」面板，用户确认后才开始下载。已有主窗口优先接收外部事件，已有面板会追加内容，多链接合并在一个面板中。

```javascript
const entry = new URL('mulee://add');
for (const link of downloadLinks) {
    entry.searchParams.append('url', link);
}
entry.searchParams.set('referrer', location.href);
entry.searchParams.set('text', window.getSelection()?.toString() ?? '');
location.href = entry.href;
```

系统也可以直接把 magnet、ed2k、thunder 链接和本地 .torrent 文件交给 Mulee；同样先确认。默认程序仅在设置·通用·默认打开方式中由用户主动设置，启动和注册自检不会抢占默认。

Debug 自检可通过 `-MuleeOpenURLDiagnostics YES` 输出收到的预填链接（不输出页面文字或密码）；常规 OpenURL 日志仅记录链接数及已有任务数。


## 安装和使用

### Safari

扩展随 Mulee.app 内置，位于 `Contents/PlugIns/MuleeSafariExtension.appex`。
在 Mulee「设置 → 通用 → 浏览器扩展」查看 Safari 启用状态，点「在 Safari 中启用」，在 Safari 扩展设置中由用户启用 Mulee。
开发期使用临时签名时，Safari 可能要求用户自行允许未签名扩展；构建和自检不会修改 Safari 设置。

Safari 优先通过 `nativeMessaging` 把入口 URL 交给扩展的 Swift handler。handler 复用 App 的 `OpenURLRequest` 校验逻辑，仅接受 `mulee://add` 及 `url`、`referrer`、`text` 字段，随后用 `NSWorkspace` 打开 URL，避免浏览器外部协议确认。native messaging 不可用时退回临时标签页交接。

### Chrome（MV3）

在 Mulee「设置 → 通用」点「安装 Chrome 扩展…」，会在访达显示 App 内置的 `BrowserExtensions/chrome` 目录，并展示操作说明：

1. 把 `chrome` 文件夹复制到固定位置，例如「文稿」，避免更新 App 后 Chrome 加载目录发生变化。
2. 在 Chrome 打开 `chrome://extensions`，启用「开发者模式」。
3. 点「加载已解压的扩展程序」，选择复制后的 `chrome` 文件夹。

也可以解压同目录的 `mulee-chrome.zip`，加载解压后的 `chrome` 文件夹。
Chrome 不允许 manifest 引用扩展目录外的文件，所以源码中的 `Extensions/Chrome/manifest.json` 需要先打包，不能直接加载源码目录。

Chrome 用 `tabs.create` / `tabs.update` 打开 `mulee://add`。首次出现「是否打开 Mulee」提示是正常行为，选择「打开 Mulee」，可勾选「始终允许」（是否提供此选项由浏览器决定）。临时交接页在切回浏览器时自动关闭；取消提示时可以点「关闭此标签页」。大批链接会分成多个入口请求，每批可能分别提示。

### 选择链接

- 在链接上右键选「用 Mulee 下载」。右键入口允许任意有效远程链接，不要求文件扩展名。
- 选中含 magnet、ed2k、thunder、HTTP(S) 或 FTP 链接的文字，右键选「用 Mulee 下载选中的链接」。选中文字也作为 `text` 传入，让 App 按用户设置识别解压密码。
- 点工具栏图标，勾选当前页面识别到的链接，再点「发送到 Mulee」。支持常见压缩包、镜像、安装包、音视频、文档和 `.torrent`，以及当前 Bilibili / YouTube 视频页面；没有匹配链接时显示空状态。浏览器内部页面不能扫描。
- 页面扫描仅在点击工具栏时执行，链接从锚点和页面文字识别。只读取顶层当前页面，不常驻注入，不跨站遍历 iframe。动态登录地址、脚本按钮和没有文件扩展名的下载可能需要右键手动发送。
- 发送携带顶层来源页面的 HTTP(S) 地址作为 `referrer`；弹窗发送的 `text` 为当前选中文字。输入按 App 的 200 条 / 1,048,576 字节上限分批，保留每批来源与文字。单个链接或文字已经超过上限时明确报错，不截断或丢弃。

### 接管浏览器下载（默认关闭）

Chrome 弹窗中的「下载接管设置」可开启「接管浏览器下载」，开启时才申请可选 `downloads` 权限；随后申请可选 `webRequest`、HTTP/HTTPS host 权限和原生连接权限，拒绝这组权限仍可接管。关闭时撤销 `downloads` 和 `webRequest` 权限；host 与原生连接权限可能仍供已授权的登录状态交接使用。扩展名列表可以编辑，空格或逗号分隔，不区分大小写，默认覆盖压缩包、镜像、安装包、大视频和 `.torrent`。

匹配下载地址或浏览器已提供的文件名时，扩展先 `downloads.pause`，再校验并交接链接。交接成功才 `cancel` + `erase`；校验失败、交接失败或超过 10 秒则尝试 `resume`，浏览器继续下载。暂停本身失败时不接管。Mulee 中仍然需要确认，不会直接开始下载；恢复失败只报告错误，不取消浏览器任务。

交接成功的判定按通道区分：
- Safari 使用现有原生 handler 的 `{ok:true}` 回复，原生失败时恢复浏览器下载，不退回协议页。当前 Safari manifest 不开放 downloads 权限，接管开关禁用，右键和工具栏仍可使用；API 均做特性检测。
- Chrome 已授权 `nativeMessaging` 且安装辅助组件时，现有宿主新增消息 `{type:"openLinks", url:"mulee://add?..."}`。`url` 沿用现有编码，包含链接、来源页、文字及 UA、文件名、一次性 Cookie token 等上下文；宿主复用 `BrowserExtensionRequest` / `OpenURLRequest` 校验。主程序未运行（不把宿主自身计为主程序）、校验失败或系统打开失败时回复 `{ok:false}`，浏览器恢复；成功打开才回复 `{ok:true}`。辅助组件安装入口沿用 Mulee 设置·视频的 Chrome 登录状态连接按钮，不自动安装。
- Chrome 未授予原生权限或宿主未安装时，按主控裁决保留协议标签页交接：成功创建交接页并存好入口后即视为交接成功。**这个回退通道无法确认 Mulee 是否收到链接**，取消外部协议提示或 Mulee 未运行时不保证自动恢复。安装辅助组件并授予原生权限后才有上述在线检查。其他原生通信错误不会退回协议页，而会恢复浏览器下载。

有 `webRequest` 权限时，仅在内存记录主框架及子资源请求的 URL、tabId、方法和记录时间，不读取请求体或请求头。按 URL + tabId 保存最近 200 条，60 秒过期，撤销权限时清空。原始 URL 或重定向后的 URL 对应请求不是 GET 时不接管；找不到记录时照常接管。Chrome 的 DownloadItem 没有 tabId，因此会保守检查同 URL 的所有近期记录，任一非 GET 就留在浏览器；提供 tabId 的平台按 URL + tabId 精确匹配。MV3 worker 重启后内存记录重新积累。

「不接管的网站」保存在 `storage.local.excludedSites`，默认 `[]`。填写域名，用空格、逗号或换行分隔；大小写会统一，支持国际化域名。`example.com` 精确匹配该域名，`*.example.com` 匹配任意层级子域名，不含根域。下载来源页、原始地址或最终地址任一命中就由浏览器下载；不影响右键或弹窗主动发送。错误格式不保存。

普通下载接管不传递请求体、Authorization 或临时请求头。按站点开启的 Cookie 交接和视频登录状态仍走各自授权的原生通道，Cookie 不进入 URL；没有方法记录时，POST 等需要原请求上下文的下载仍可能无法在 Mulee 使用。

## 权限与隐私

基础权限仅 `contextMenus`、`activeTab`、`scripting`、`storage`。`activeTab` 只在用户操作时临时授权当前页面，`scripting` 只扫描当前页面，`storage.local` 只保存接管开关、扩展名列表、站点例外、视频登录状态传递开关及主动授权的下载站点；临时交接 URL 使用 `storage.session`，取用后移除。不声明常驻 `<all_urls>` 或 host 权限。
Chrome 仅在用户开启接管时申请 `downloads`，并可选申请 `webRequest`、`nativeMessaging` 和 HTTP/HTTPS host 权限；视频登录状态使用独立的可选授权，见下文。Safari 基础权限额外使用 `nativeMessaging`，只与随 App 内置的 handler 通信。

扩展不联网、不发送遥测，只把你点选的链接（或明确开启接管后匹配的下载）、来源地址及选中文字交给本机 Mulee。页面文字与链接均视为不可信输入，界面用 `textContent` 展示，禁止执行网页提供的代码。扩展资源采用仅本地脚本的 CSP，并禁止扩展发起网络连接。明确开启视频登录状态传递时，还会通过独立 native messaging 交接两站 Cookie。App 自身的下载行为仍须在新建面板中确认。

相关平台接口：[Chrome 可选权限](https://developer.chrome.com/docs/extensions/reference/api/permissions)、[Safari native messaging](https://developer.apple.com/documentation/safariservices/messaging-between-the-app-and-javascript-in-a-safari-web-extension)。

## 视频登录状态（默认关闭）

扩展弹窗的「视频登录状态」中提供「把 B 站 / YouTube 登录状态交给 Mulee，用于下载需要登录的画质」开关。只有用户开启时才申请 `cookies` 和 `https://*.bilibili.com/*`、`https://*.youtube.com/*` 可选 host 权限；Chrome 同时申请可选 `nativeMessaging`。不开启、拒绝授权或撤销权限时不读取 Cookie。

开启时与「更新登录状态」按钮会同步两站；此后只在用户向 Mulee 发送对应站点链接时刷新该站（包括 b23.tv / youtu.be 短链接，但读取的 Cookie 域仍仅为两站根域及子域）。只调用这两个根域的 cookies API，并再次过滤域名。YouTube 的 `google.com` Cookie 不在范围内。Cookie 不保存到扩展 storage，不记录到控制台，绝不拼入 `mulee://`、临时交接页或浏览器历史；native 通道失败时显示错误，不退回 URL。关闭开关撤销 Cookie/host 权限；App 中已保存的状态由用户在设置·视频中清除。

### Safari：App Group 交接，App 钥匙串保存

Safari → `SafariWebExtensionHandler` 接收独立的 `videoCookies` JSON 消息。使用 `LV69DG6R9Y.com.cqagc.mulee.video-login` App Group；两 target 都声明相同 entitlement。共享目录通过 `FileManager.containerURL` 获取，目录 0700、文件创建即 0600，随机暂存文件加原子 rename 交接。App 在准备视频任务或显示视频设置时认领文件，校验后优先保存到本机 data protection keychain，再删除交接文件。缺少钥匙串 entitlement 时使用下述 0600 本机文件回退。钥匙串暂不可用时保留 0600 交接以便重试，不回退到公共目录。

[Apple 的 App Group 授权说明](https://developer.apple.com/documentation/xcode/accessing-app-group-containers)明确支持 macOS 的 `<Developer team identifier>.<group name>` 格式：Developer ID 签名的 Team ID 与前缀一致即可，无需描述文件或网站注册。`group.` 前缀需要描述文件，故此处采用 Team ID 前缀；macOS 26 满足平台要求。临时 ad hoc 签名不具备真实 Team ID，不能据此宣称 Safari 交接可用；无法获取授权容器时拒绝消息。正式签名容器交接尚需在已启用扩展的 Safari 中人工验收。

### Chrome：用户主动安装 Native Messaging 宿主

在 Mulee 设置·视频点击「安装 Chrome 登录状态连接」，只写入：

```
~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.cqagc.mulee.video_login.json
```

宿主为当前 Mulee.app 内的主可执行文件，无新增依赖或独立脚本。Chrome 传入扩展 origin 时入口在创建 SwiftUI App、引擎、任务存储之前进入命令行模式，仅处理一个 stdin/stdout 长度帧并退出。`allowed_origins` 只含 manifest 固定公开 key 对应的 Mulee 扩展 ID，宿主还复核 argv origin。固定 key 仅用于稳定未打包扩展 ID，不是秘密或私钥。App 移动后需要用户再次点击该按钮更新绝对路径。实现遵循 [Chrome Native Messaging 协议](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging)。本次开发与测试不在用户真实浏览器目录安装宿主，也不加载扩展或更改浏览器设置。

### 校验与任务内使用

消息仅含 `type`、`site`、`cookies`；最大 524,288 字节、256 个 Cookie；域名必须严格属于声明的站点，拒绝旁站、伪造后缀、额外字段、非法类型、控制字符、过长字段或非法到期时间。native 帧在读取正文前检查长度，截断帧拒绝。任何错误回复只含布尔状态，不回显凭据。钥匙串使用设备本地、首次解锁后可访问、不经 iCloud 同步的条目。

免描述文件 App Group 的容器权限与钥匙串访问组是两回事；Team ID 前缀 App Group 不自动提供可用的 keychain access group，见 [Apple 的 Mac 钥匙串说明](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)。仅遇到 `errSecMissingEntitlement` 才回退到 `~/Library/Application Support/Mulee/VideoLogin/<site>.json`，目录 0700、原子写入的文件 0600，读取也校验文件类型、权限、长度和站点；设置·视频如实说明这一存储方式。钥匙串锁定或其他访问错误会报错，不静默回退。清除同时处理两种存储；后续钥匙串写入成功会删除旧文件。

yt-dlp 每个子进程读取该站登录状态后，创建独立的 Netscape cookies.txt（`O_EXCL | O_NOFOLLOW`，0600），支持 HttpOnly、hostOnly、会话和过期 Cookie；进程结束、下载失败、暂停、移除、引擎停止或重试退出旧 worker 后删除文件；监督进程也会在 App 异常退出并终止子进程后删除该文件。凭据不写入 tasks.json、jobs.json、命令参数值或日志。使用凭据时不保存 yt-dlp 原始错误文本，防止工具错误输出回显凭据。不使用 `--cookies-from-browser`。没有保存登录状态时不增加 `--cookies`，沿用原行为。

## B 站分 P / 合集

新建下载的 B 站选项异步获取 yt-dlp `--flat-playlist --yes-playlist -J` 列表，取列表时移除原链接的 `p` 参数，保留其默认选中语义。总超时 20 秒、子进程输出上限 4 MiB、最多 1,000 项；切换或关闭面板会取消对应请求并终止进程。不在打开面板时安装工具。

yt-dlp 当前的 Bilibili flat entries 只有分 P 地址，没有标题，因此通过无 Cookie 的临时 URLSession 读取 B 站公开视频元数据补齐标题；单视频所属 `ugc_season` 合集也从该元数据取得。没有公开元数据时保留 yt-dlp 返回的地址，不把缺失元数据冒充完整合集。多于一项时显示复选框，默认选择原链接当前 P（合集优先匹配当前 BV），可全选或全不选；全不选不能确认。列表失败显示提示，仍可按原行为下载当前视频。

每个选中项创建独立任务，带原有来源上下文；分 P URL 显式指定 `p`，引擎使用 `--no-playlist --playlist-items <P>`，文件名含 P 序号及 yt-dlp 的分 P 标题，独立暂停、恢复及重试。合集条目保留各自 BV 地址，P 序号按列表顺序。YouTube 播放列表勾选未实现，单视频下载与 Cookie 支持已接入。

### 本次验证边界

`/opt/homebrew/bin/yt-dlp` 2026.08.19 对公开地址 `https://www.bilibili.com/video/BV1bK411W797` 无账号 Cookie 执行 `--ignore-config --flat-playlist --yes-playlist -J --socket-timeout 10 --retries 0 --no-cache-dir`，退出码 0，返回 23 项，前两项分别为 `?p=1`、`?p=2`。另以无 Cookie 请求公开元数据接口，返回 23 个分 P 标题。该结果验证分 P 列表提取，不代表登录画质下载或浏览器端到端已实测；未使用任何真实账号 Cookie。

构建与签名完成后，直接运行 App 的命令行宿主：其他扩展 origin 退出码 1 且无 stdout；Mulee origin 携带非法站点请求时退出码 1，返回长度 12 的 `{"ok":false}` 帧。没有调用真实用户的宿主安装按钮，也没有导入账号 Cookie。Chrome 浏览器实际启动宿主、Safari 正式签名容器交接和登录画质下载未做实机验收；App 测试宿主中的帧、origin/manifest、消息校验与分 P 生成测试单独通过。

自动化结果：MuleeCore 196 项（`--no-parallel` 复测）、MuleeTests 194 项、JS 25 项通过；`python3 -I scripts/check-l10n.py build/dd Debug` 通过，`codesign --verify --deep --strict` 通过。一次并行全量复测的既有 ECClient 取消/超时测试出现超时，未改动该模块；串行全量复测通过。没有 Swift 编译警告，Xcode 仍输出未依赖 AppIntents.framework 的元数据提取提示。界面使用原生复选框、进度条、按钮和站点明确的清除标签；未实测 VoiceOver。

## 构建与测试

```sh
scripts/package-extensions.sh
node --test Extensions/Shared/tests/*.test.js
xcodegen generate
xcodebuild -project Mulee.xcodeproj -scheme Mulee -destination 'platform=macOS,arch=arm64' test
```

打包脚本生成 `build/extensions/chrome/`、`build/extensions/mulee-chrome.zip` 及 `build/extensions/safari/`。脚本仅复制纯 JS / HTML / CSS / `_locales`，从 `Design/Brand/mulee-icon-1024.png` 用系统 `sips` 生成图标，不需要第三方依赖或 JS 打包工具。Chrome 和 Safari 使用同一份 Shared 代码；默认简体中文，并提供英文、繁体中文和日文。App 构建阶段自动内置 Chrome 文件夹、zip 和安装说明；Safari target 构建阶段自动打包 Shared 资源并嵌入主 App。

`BrowserExtensionRequestTests` 使用与 handler 相同的校验器，验证协议、额外字段、本地文件 / thunder、混合输入以及条数和字节限制。JS 测试覆盖识别、去重、编码往返、分批及边界。

构建后检查 `Mulee.app/Contents/PlugIns`、`codesign --verify --deep --strict Mulee.app`；注册自检须先取得 `/tmp/mulee-e2e.lock` 目录锁并确认 `pgrep -x Mulee` 为空，再启动一次构建的 App，使用 `pluginkit -m -p com.apple.Safari.web-extension` 查询。完成后退出本次 App 并释放锁。该检查不等同于扩展已在 Safari 启用，不安装 Chrome 扩展，也不修改用户浏览器设置。

### X1 定向验证

新增 JS 测试使用假的 downloads API，覆盖暂停 → 交接 → 取消 / 清理顺序、暂停失败、校验失败、原生拒绝 / 通信失败、10 秒超时及迟到回复、恢复分支、清理失败、POST 跳过、GET / 无记录接管、记录容量 / 过期、域名及通配匹配、可选权限拒绝和设置保存。Swift 的 `VideoLoginTests` 覆盖 `openLinks` 校验、主程序未运行、系统打开失败和帧长度边界；原生帧上限为 1,048,704 字节（1 MiB 入口 URL 加 JSON 信封空间），Cookie 消息仍由原有解析器执行各自更小的长度限制。

211 执行 `~/.config/mulee/remote.sh ext` 验证扩展；Swift 定向执行 `~/.config/mulee/remote.sh test -only-testing:MuleeTests/VideoLoginTests -only-testing:MuleeTests/BrowserExtensionRequestTests -only-testing:MuleeTests/HTTPDownloadTests -only-testing:MuleeTests/ExtensionHandoffTests`。这不代表真实 Chrome / Safari 接管或用户权限提示已经验收；本任务未安装宿主、加载扩展或操作正在运行的 Mulee。

并行验证中若共享构建目录出现数据库锁冲突，X1 使用独立目录和日志复测（仍只在远端构建，不操作用户的 App）：

```sh
~/.config/mulee/remote.sh sh 'xcodegen generate -q && xcodebuild test -project Mulee.xcodeproj -scheme Mulee -destination "platform=macOS,arch=arm64" -derivedDataPath build/w1-ext-dd CODE_SIGN_IDENTITY=- -only-testing:MuleeTests/VideoLoginTests -only-testing:MuleeTests/BrowserExtensionRequestTests -only-testing:MuleeTests/HTTPDownloadTests -only-testing:MuleeTests/ExtensionHandoffTests > build/w1-ext-test.log 2>&1'
```

X1 本轮结果：远端 `remote.sh ext` 为 78 项通过、0 失败；`remote.sh build` 输出 `BUILD SUCCEEDED`（已修复原生宿主帧长度常量的 actor 隔离错误）。四组 Swift 定向测试尚未完成：共享目录曾遇到构建数据库锁，独立目录复测又被其他进行中改动的 `VolumeAvailabilityMonitorTests` 初始化参数不匹配阻断。主控将在合拢后统一验证；不能把本次 Swift 编译尝试记为测试通过。
