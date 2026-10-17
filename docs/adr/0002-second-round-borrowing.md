# ADR-0002：第二轮借鉴：视频、安全、HTTP、BT 与队列

状态：已采纳（2026-10-17）　基线：`d15aff0`　目标：下一次发版（版本号发版时再定）

## 背景

在 ADR-0001 的基础上，又调研了 Transmission（重点是 macOS 原生客户端）、Xtreme Download Manager 和 Parabolic（yt-dlp 图形前端）。只借鉴设计思想，**不复制、不改写任何参考仓库的源码**；参与开发的人不打开参考仓库。

调研中确认的 Mulee 缺口：

| 缺口 | 后果 |
|---|---|
| 下完的文件不带 `com.apple.quarantine` | 下载的 .dmg、.app、.pkg 首次打开时 Gatekeeper 不检查 |
| 扩展接管下载时先取消浏览器下载、再交给 Mulee | Mulee 没运行、交接失败或原请求是 POST 时，浏览器那份已经没了 |
| aria2 不读 macOS 系统代理 | 用「系统代理」模式（不是虚拟网卡）的用户，浏览器能下的文件 Mulee 直连下不动 |
| 保存目录所在的卷被拔掉后只报 I/O 错误 | 插回去也不会自动继续 |
| 睡眠醒来后旧连接失效 | 可能耗光重试次数，任务直接失败 |
| YouTube 播放列表链接只下当前一集或整体塞进一个任务 | 选不了集；纯播放列表链接读格式会超时 |
| 字幕只对 B 站生效；没有仅音频、元数据嵌入、时间段 | 常见视频需求做不了 |
| BT 单文件进度只算完整分块，总进度算未完成分块里已下的块 | 同一任务显示 16% 和 12% |
| HTTP 只能下完后播放 | 大视频要等全部下完 |
| 卡住的任务一直占并发名额；不能调顺序、不能排序 | 队列被一两个慢任务堵住 |

## 不借

- 资源搜索、种子站、RSS、插件市场、Web 远程管理、P2SP（产品红线，同 ADR-0001）。
- `--cookies-from-browser`（要读浏览器的钥匙串条目和 Cookie 库，超出 Mulee 的权限边界）。
- 自由文件名模板（容易写出非法路径；只给预设）。
- SponsorBlock 删除片段（只做章节标记，不改内容）。
- 完成后运行任意 shell 脚本（改为运行用户选定的快捷指令）。

## 决定

通用约定同 ADR-0001：设置项走 `SettingsModel`，键名 `分组.名称`，每个设置都要真正生效并被 `SettingsReadCoverageTests` 覆盖；新增文案补齐 en / zh-Hant / ja（工人只写中文原文，翻译最后统一补）；界面文案讲清「现在什么情况、有什么影响、怎么解决」。

### V1 YouTube 播放列表勾选（视频）
- `LinkParser` 识别 YouTube 的 `list=`：`watch?v=X&list=Y` 和 `/playlist?list=Y` 都是视频链接，附带 `playlistID`。
- 新建面板的分集列表从「只做 B 站」泛化为按站点：YouTube 用 `yt-dlp --flat-playlist --yes-playlist -J --playlist-end 1000` 取条目；每条变成单视频地址 `https://www.youtube.com/watch?v=<id>`，标题显示 `#序号 标题`，有时长就显示时长。
- 默认勾选：链接带 `v=` 时只勾这一集；纯播放列表链接默认全不勾，至少勾一项才能开始；有「全选 / 全不选」。
- 读格式一律用单视频地址（去掉 `list=`）。纯播放列表链接**永远不会**作为一个整体任务下载。
- 选中 ≥2 项时提供「放进以列表名命名的子文件夹」，默认开；文件名带序号前缀（与 B 站分 P 一致）。
- Cookie 按站点取（YouTube 取 YouTube 的登录状态）。

### V2 字幕（视频）
- `-J` 已拿到的 `subtitles` 与 `automatic_captions` 在新建面板里列成语言勾选（默认勾选：设置里的首选语言中存在的那些）。
- 设置：`video.subtitleMode`：`off`（默认）/ `embed` / `file`；`video.subtitleLanguages`（字符串列表，默认取系统首选语言映射，如 `zh-Hans`、`en`）；`video.autoCaptions` 默认关。
- 参数：`--write-subs`（+ `--write-auto-subs`）、`--sub-langs`、`--convert-subs srt`（file 模式）或 `--embed-subs`（embed 模式）。
- B 站现有的 CC 字幕与弹幕逻辑保持不变，`video.ccSubtitles` 继续只管 B 站。

### V3 仅音频（视频）
- 新建面板画质选项增加「仅音频」；设置 `video.audioFormat`：`m4a`（默认）/ `mp3`。参数 `-f bestaudio -x --audio-format <fmt>`。

### V4 元数据、封面、章节（视频）
- 设置 `video.embedMetadata` 默认开：`--embed-metadata --embed-chapters --embed-thumbnail`。容器不支持封面（如 webm）时只嵌元数据，不能让任务失败。

### V5 赞助片段标记（视频）
- 设置 `video.sponsorBlockMark` 默认关，只对 YouTube 加 `--sponsorblock-mark sponsor,selfpromo,intro,outro`。说明文案写明会访问 SponsorBlock 公共服务。

### V6 编码与帧率偏好（视频）
- 设置 `video.codecPreference`：`auto`（默认）/ `h264` / `hevc` / `av1` / `vp9`；`video.prefer60fps` 默认关。用 `-S` 排序实现，与现有「兼容优先 / 画质优先」两档组合；兼容优先档在 `auto` 时行为不变。

### V7 文件名预设（视频）
- 设置 `video.filenamePreset`：`title`（默认，现状）/ `uploaderTitle` / `dateTitle`。模板内部写死，字节长度限制保持 160B。

### V8 时间段下载（视频）
- 新建面板高级选项里可填开始、结束时间（`hh:mm:ss` 或秒）；参数 `--download-sections "*start-end"`。只对单个视频生效；播放列表多选时隐藏。

### V9 重复检测（新建面板）
- 视频：`-J` 的 `extractor_key` + `id` 作为 `videoIdentity` 存进任务；新建时命中已有任务（未删除）给出提示「这个视频已在任务列表里」和「显示任务」按钮，不阻止添加。
- HTTP：链接去掉 fragment 后与已有任务的来源链接比对，命中时提示「这个链接下载过」，文件还在就给「在访达中显示」。不阻止添加。

### S1 隔离属性与来源（所有引擎）
- 任务完成并改回正式文件名之后，给成品设置 `NSURLQuarantinePropertiesKey`（类型 download、代理名 Mulee、来源地址）和 `kMDItemWhereFroms`（来源地址、来源页）。
- 来源地址写入前去掉账号口令、query 和 fragment；磁力、ed2k 链接只写 `magnet:` / `ed2k:` 协议名加文件名，不写 hash 以外的参数。
- 目录（BT 多文件、解压结果）对其中的普通文件和 `.app` 包逐个设置，单任务最多 10000 项。设置失败只记日志，不影响任务状态。
- 不提供开关（这是安全默认行为）。

### S2 未完成目录不进时间机器
- HTTP 的 `.mulee-incomplete` 目录创建时设 `isExcludedFromBackup`。只设目录本身，文件移出后不带这个属性。BT 的 `.mulee` 文件不处理（属性会随改名跟到成品上，风险大于收益）。

### S3 卷断开与重新连接
- 新暂停原因 `volumeUnavailable`。监听 `NSWorkspace.didUnmountNotification` / `didMountNotification`，启动时也检查：保存目录所在卷不在了，暂停写入它的全部任务，状态显示「保存位置所在的磁盘已断开」，横幅说明怎么办（重新连接磁盘 / 换保存目录）。
- 卷回来后只恢复因这个原因暂停的任务；用户期间手动暂停的不恢复。

### S4 睡眠与唤醒
- 设置 `general.pauseOnSleep` 默认开：`willSleepNotification` 时暂停 HTTP 和视频任务（新暂停原因 `systemSleep`），`didWakeNotification` 后等网络可用（最多 30 秒）再恢复这些任务。BT、电驴不暂停。
- 低电量模式下 `SleepPreventer` 不持有防睡眠断言，界面说明原因。

### S5 Dock 徽标与 Dock 菜单
- 设置 `general.dockBadge`：`none` / `active`（默认，正在下载的任务数）/ `speed`（下载速度，如 `12M`）。
- `applicationDockMenu`：新建下载、暂停全部、继续全部、慢速模式（勾选态）。

### S6 完成后运行快捷指令
- 设置 `general.completionShortcut`（快捷指令名，默认空 = 不运行）；设置页从 `shortcuts list` 读出列表供选择。
- 每个任务完成后运行 `/usr/bin/shortcuts run <名称> --input-path <成品路径>`，参数用数组传入，不经过 shell。失败发一条通知，说明快捷指令名和错误，不影响任务。

### H1 HTTP 代理
- 设置 `network.httpProxyMode`：`system`（默认）/ `off` / `manual`；`network.httpProxyURL`（`http://host:port`，手动模式用）；代理口令存钥匙串 service `com.cqagc.mulee.proxy`。
- `system`：读 `CFNetworkCopySystemProxySettings`，优先 HTTPS 代理、其次 HTTP 代理；只有 SOCKS 代理时不用代理，并在网络设置里说明「aria2 只支持 HTTP 代理」。PAC 不支持，同样说明。系统例外列表并入 aria2 `no-proxy`，本机地址始终例外。
- 作用范围：aria2（`all-proxy`，启动时与系统代理变化时用 `changeGlobalOption`）、yt-dlp（`off` 时 `--proxy ""`，`manual` 时 `--proxy <url>`，`system` 时不加参数，yt-dlp 自己读系统代理）、Mulee 自己的预检请求（`URLSession` 按同一模式配置）。BT 和电驴不走代理。
- 代理 URL 不进日志明文（口令部分打码）。

### H2 HTTP 认证与证书错误
- HTTP 任务因 401 失败时，详情栏提供「输入账号和密码」：存钥匙串 service `com.cqagc.mulee.http-auth`、account 为主机名；重试时用 aria2 `http-user` / `http-passwd`，只对原始主机生效（沿用 ADR-0001 的跨主机不带凭据规则）。
- TLS 证书错误单独归类，文案「服务器的安全证书无效，Mulee 不会继续连接」，不再显示为普通网络错误。

### H3 Metalink 与镜像
- 支持 `.metalink` / `.meta4` 文件（打开、拖入、新建面板）与以这两种扩展名结尾的链接，交给 aria2（`addMetalink` / `follow-metalink`）。
- HTTP 详情栏「添加镜像地址」：对正在下载的任务用 `aria2.changeUri` 追加同一文件的其他地址。添加前用预检比对大小（以及 ETag 如有），不一致拒绝。

### H4 HTTP 边下边播
- 视频类 HTTP 任务在下载中也能「播放」：开启时对该任务 `changeOption stream-piece-selector=inorder`，用 `tellStatus` 的 `bitfield`、`numPieces`、`pieceLength` 算出从头连续完成的字节数，复用 BT 的缓冲阈值（20 MB 或 5%），到阈值后用播放器打开未完成文件（`.mulee-incomplete` 里的路径）。停止播放时恢复原来的分块策略。

### B1 BT 进度口径统一
- `file_progress` 不再用 `piece_granularity`，单文件进度和总进度都按已下载的块算；边下边播仍用连续完成字节判断。

### B2 磁力链接与原种子文件
- torrentd 新命令 `magnet_uri {id}` → `{uri}`（libtorrent `make_magnet_uri`）；右键菜单「复制磁力链接」对所有有元数据的 BT 任务可用。
- 设置 `bt.trashTorrentAfterAdd` 默认关：从访达打开、拖入的 .torrent 添加成功后移到废纸篓（`NSFileManager.trashItem`）。监视文件夹的文件仍按 ADR-0001 移到 `.mulee-added`。

### B3 IP 黑名单网址
- 设置 `bt.ipBlocklistURL`（默认空）。填了就每 7 天下载一次（支持 gzip），解析成功后替换，失败保留旧名单并在设置页显示上次结果。与本地路径同时存在时两者合并。

### B4 单任务限速（torrentd 部分）
- torrentd 新命令 `set_task_limits {id, download_limit, upload_limit}`（字节/秒，0 = 不限），作用于 `torrent_handle::set_download_limit` / `set_upload_limit`。与做种策略的「降速」取较小值：torrentd 记住用户值和策略值，实际生效取 min。

### Q1 单任务限速与优先级（界面与调度）
- 详情栏对 HTTP 和 BT 任务提供下载限速、上传限速（BT），持久化在任务上（`DownloadTask.downloadLimit`、`uploadLimit`，字节/秒，nil = 不限）。HTTP 用 aria2 `changeOption max-download-limit`，BT 用 B4 的命令。全局限速仍然生效，取较小值。
- 优先级 `DownloadTask.priority`：`high` / `normal`（默认）/ `low`；放行顺序：先按优先级，同级按队列位置。右键菜单「移到队列最前 / 最后」。

### Q2 卡住让位
- 设置 `download.stalledYieldMinutes` 默认 10（0 = 不让位）：正在下载的任务连续这么久速度为 0，就不再占并发名额，让后面的任务开始；它本身继续保持连接，恢复速度后重新计入名额（可以暂时超过上限，不主动暂停别人）。列表里显示「卡住，已让出名额」。

### Q3 列表排序
- 任务列表支持按 添加时间（默认，新的在上）/ 名称 / 大小 / 进度 / 速度 / 状态 排序，升降序可切换，保存在 `ui.taskSort`。排序不改变队列位置。

### X1 扩展接管的安全网
- 接管顺序改为：`downloads.pause` → 交给 Mulee → 成功则 `cancel` + `erase`，失败则 `resume`，浏览器继续下。
- 可选权限 `webRequest`（随「接管下载」一起申请，用户拒绝也不影响接管）：有权限时记录请求方法，非 GET 的下载不接管。
- 设置「不接管的网站」列表（域名，支持 `*.example.com`），默认空。

### QL Quick Look 预览种子
- 新增 Quick Look 预览扩展：在访达里按空格预览 .torrent，显示名称、总大小、文件树（最多 500 项）、tracker、是否私有、创建工具。复用 MuleeCore 的种子解析；扩展跟主程序一起签名公证，release.sh 签名检查覆盖扩展。

## 不可回归
- ADR-0001 的全部不可回归项。
- B 站分 P、番剧列表、CC 字幕、弹幕的现有行为。
- 扩展的链接交接、登录状态交接、按站点 Cookie 交接。
- 代理设置为 `system` 而系统没开代理时，与现在行为完全一致。
- 不新增任何会把 Cookie、口令、代理口令写进日志、URL、任务历史明文的路径。

## 后果
- 新暂停原因 `volumeUnavailable`、`systemSleep`；任务新增字段 `videoIdentity`、`downloadLimit`、`uploadLimit`、`priority`。
- torrentd 新命令 `magnet_uri`、`set_task_limits`；`file_progress` 口径变化。
- 扩展新增可选权限 `webRequest`。
- 新增 Quick Look 扩展 target。

## 裁决记录
</content>
</invoke>
- H2 认证（2026-10-17 开发中改定）：aria2 的 `http-user` / `http-passwd` 是任务级选项，跳转到别的主机后对方再要求认证时仍可能发出去，所以不用它，也不用 netrc。账号口令转成 `Authorization: Basic` 头，走 ADR-0001 的凭据头通道：Mulee 先预检解析跳转，最终主机与原始主机相同才附加。口令只在钥匙串，任务历史只记「使用钥匙串里的认证」。
- X1 交接确认（2026-10-17 开发中改定）：Chrome 的交接标签页无法确认 Mulee 收到了链接。Safari 以原生 handler 的回复为准；Chrome 装了辅助组件（native 宿主）时，宿主新增 `openLinks` 消息，复用 `OpenURLRequest` 校验后打开 `mulee://add`，打开成功才算交接成功；没装辅助组件时仍用交接标签页，顺序改为暂停 → 打开交接页 → 成功后取消，任何一步出错就让浏览器继续下载。
- V1/V2 元数据接口：`-J` 的解析集中在 `YtDlpVideoMetadata`（格式、视频标识、字幕语言、自动字幕语言、标题、时长），播放列表、重复检测、字幕选择共用，不各自解析。
- H3 Metalink（2026-10-17 开发中改定）：原来编译 aria2 时关掉了 XML，RPC 没有 `addMetalink`。改为开启 metalink，XML 解析用 macOS 自带的 libxml2，仍然只依赖系统库。
- H1 代理口令：yt-dlp 的原始错误信息可能带代理地址，显示前统一打码。
- 交叉审查（第一波，6 条）：
  - 采纳：带 Cookie 或认证的 HTTP 任务，预检改用 GET（只取响应头），按实际下载的跳转链判断主机，再把最终地址交给 aria2；跨主机仍不带凭据。只用 HEAD 时，服务器可能对 GET 另行跳转到别的主机。
  - 采纳：代理口令不写进 aria2.conf，aria2 启动后经 RPC 下发。
  - 采纳：扩展确认交接成功后，取消浏览器下载失败时不再恢复它，保持暂停并提示，避免两边同时下载；原生交接超时同样保持暂停并提示，只有明确失败才恢复。
  - 采纳：yt-dlp 读播放列表、读格式也按代理设置传参。
  - 部分采纳：认证头会随 aria2 会话保存。沿用 ADR-0001 定的保护边界（0700 状态目录、会话文件 0600），与 Cookie 相同；H2 里「口令只在钥匙串」改为「口令长期只存钥匙串，运行中的 aria2 会话文件受状态目录保护」。
- Q1/Q2 并发语义：调低并发上限立即生效，多出的下载任务回到排队（与现状一致）。例外只有两个：卡住让位的任务恢复速度后可以暂时超出上限；调整优先级、移到队列最前只影响排队任务的放行顺序，不抢占正在下载的任务。
- 交叉审查（第二批，3 条，全部采纳）：aria2 从会话文件恢复的任务在连接前补下发代理凭据；视频引擎调高并发只补开新进程，不重启已有的 yt-dlp；带凭据的零字节文件对一字节 Range 返回 416 时按空文件放行。
- 本地化（2026-10-17）：本轮 MuleeCore 新增的用户可见文案（报错、代理说明、播放列表回退名）一律走 `String(localized:bundle: .module)` 并补齐三种语言。`HTTPDownloadFailure.requiresCredentials` 不再靠比较文案判定。Quick Look 扩展有自己的字符串目录。
- 真实网络验收（2026-10-17，211 上用真实 yt-dlp 与 YouTube 播放列表）发现并已修：内置静态 ffmpeg 读不到系统根证书，时间段下载在 HTTPS 上必然失败（yt-dlp 子进程默认注入 `SSL_CERT_FILE=/etc/ssl/cert.pem`，调用方已设置时不覆盖）；有时间段时不嵌章节、不加赞助片段标记；「嵌入」字幕成功后清理本任务留下的字幕文件；「兼容优先」配合编码偏好时保留 AAC 音轨约束（设置页注明 AV1、VP9 在系统播放器里可能放不了）；纯播放列表链接在模型层兜底，不经新建面板的入口不会把整个列表建成一个任务，快捷指令后台调用时返回明确错误。
- Metalink 用真实 MirrorBrain 站点验证：新编的 aria2 只链接系统库，下载并校验成功。
- 发版前检查（2026-10-17，未发版）：211 上 Release 构建通过，Release 翻译门禁 0 缺失；Release 产物（含重编的 aria2 与新的 Quick Look 扩展）用 `privacy-check.py --app` 扫原始字节通过。
- 视觉验收：两台测试机夜间锁屏，改用离屏渲染（NSHostingView + cacheDisplay）给新界面出图，中英文、浅深色共 76 张。据图修整：重复提示与链接行左对齐；时间段输入框加可见标签；代理说明不出现 aria2；AV1/VP9 提示只在相关组合下显示；字幕不下载时新建面板不显示字幕语言。
