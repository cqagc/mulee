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

Chrome 弹窗中的「下载接管设置」可开启「接管浏览器下载」，开启时才申请可选 `downloads` 权限；关闭时撤销权限。扩展名列表可以编辑，空格或逗号分隔，不区分大小写，默认覆盖压缩包、镜像、安装包、大视频和 `.torrent`。
匹配浏览器开始的下载时，扩展先校验 URL，再取消该下载，把链接交给 Mulee 的确认面板；不会自动在 Mulee 开始下载。根据下载地址或浏览器已提供的文件名匹配，不按文件大小推断。

需要登录 cookie、POST 请求或临时请求头的下载可能失败；失败时可临时关闭接管，再用浏览器下载。扩展不读取或传递 cookie、请求体、Authorization 或其他请求头。取消后的浏览器下载不会自动恢复，用户仍可重新点击原链接。
Safari 没有提供对应 downloads API 时，接管开关禁用并显示原因，右键和工具栏选择仍可使用。

## 权限与隐私

基础权限仅 `contextMenus`、`activeTab`、`scripting`、`storage`。`activeTab` 只在用户操作时临时授权当前页面，`scripting` 只扫描当前页面，`storage.local` 只保存接管开关和扩展名列表；临时交接 URL 使用 `storage.session`，取用后移除。不声明常驻 `<all_urls>` 或 host 权限。
Chrome 仅在用户开启接管时申请 `downloads`；Safari 额外使用 `nativeMessaging`，只与随 App 内置的 handler 通信。

扩展不收集任何数据、不联网、不发送遥测，只把你点选的链接（或明确开启接管后匹配的下载）、来源地址及选中文字交给本机 Mulee。页面文字与链接均视为不可信输入，界面用 `textContent` 展示，禁止执行网页提供的代码。扩展资源采用仅本地脚本的 CSP，并禁止扩展发起网络连接。App 自身的下载行为仍须在新建面板中确认。

相关平台接口：[Chrome 可选权限](https://developer.chrome.com/docs/extensions/reference/api/permissions)、[Safari native messaging](https://developer.apple.com/documentation/safariservices/messaging-between-the-app-and-javascript-in-a-safari-web-extension)。

## 构建与测试

```sh
scripts/package-extensions.sh
node --test Extensions/Shared/tests/*.test.js
xcodegen generate
xcodebuild -project Mulee.xcodeproj -scheme Mulee -destination 'platform=macOS,arch=arm64' test
```

打包脚本生成 `build/extensions/chrome/`、`build/extensions/mulee-chrome.zip` 及 `build/extensions/safari/`。脚本仅复制纯 JS / HTML / CSS / `_locales`，从 `Design/Brand/mulee-icon-1024.png` 用系统 `sips` 生成图标，不需要第三方依赖或 JS 打包工具。Chrome 和 Safari 使用同一份 Shared 代码；默认简体中文，并提供英文和繁体中文。App 构建阶段自动内置 Chrome 文件夹、zip 和安装说明；Safari target 构建阶段自动打包 Shared 资源并嵌入主 App。

`BrowserExtensionRequestTests` 使用与 handler 相同的校验器，验证协议、额外字段、本地文件 / thunder、混合输入以及条数和字节限制。JS 测试覆盖识别、去重、编码往返、分批及边界。

构建后检查 `Mulee.app/Contents/PlugIns`、`codesign --verify --deep --strict Mulee.app`；注册自检须先取得 `/tmp/mulee-e2e.lock` 目录锁并确认 `pgrep -x Mulee` 为空，再启动一次构建的 App，使用 `pluginkit -m -p com.apple.Safari.web-extension` 查询。完成后退出本次 App 并释放锁。该检查不等同于扩展已在 Safari 启用，不安装 Chrome 扩展，也不修改用户浏览器设置。
