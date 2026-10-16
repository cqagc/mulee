# ADR-0001：借鉴同类下载器的功能与体验

状态：已采纳（2026-10-16）　基线：`9efd7fc`　目标：下一次发版（版本号发版时再定）

## 背景

调研了 Gopeed（GPL-3.0）、AB Download Manager（Apache-2.0）、Motrix（MIT）、qBittorrent（GPLv2+）、Persepolis（GPL-3.0）的源码，以及迅雷的公开产品功能。只借鉴设计思想，**不复制、不改写任何参考仓库的源码**；参与开发的人不打开参考仓库。

调研中发现的 Mulee 自身缺口：

| 缺口 | 后果 |
|---|---|
| HTTP 下载交给 aria2 时只传了保存目录和是否暂停；来源页、请求头、建议文件名都丢了；User-Agent 固定为 `Mulee/0.1` | 需要登录、有防盗链或拒绝非浏览器 UA 的文件下载失败 |
| 没有重试次数、重试间隔、低速判定 | 网络抖动时任务直接失败或长期卡住 |
| 磁盘写满前没有任何保护 | 系统和其他应用一起出问题；任务看起来像卡住 |
| 没有系统通知、没有下完后动作 | 下完不知道；挂机下载要人守着 |

## 不借

- 资源搜索、种子站、资源推荐、RSS 自动下载（产品红线）
- 迅雷 P2SP、云盘、离线下载（红线，且依赖厂商服务器）
- 插件或扩展市场（第三方「网址解析」插件容易变成资源站入口）
- Web 远程管理、服务器版
- 靠模拟鼠标移动防睡眠、需要 sudo 密码的关机方式

## 决定

设置项一律走 `SettingsModel`，键名按 `分组.名称`；每个设置都要真正生效，并被 `SettingsReadCoverageTests` 覆盖。新增文案补齐 en / zh-Hant / ja。界面文案讲清「现在什么情况、有什么影响、怎么解决」。

### A1 浏览器请求上下文与 HTTP 稳健性（HTTP 引擎、扩展）
- MuleeCore 新增 `DownloadRequestContext`：`referer: URL?`、`userAgent: String?`、`suggestedFilename: String?`、`headers: [String: String]`、`cookie: String?`。HTTP 任务添加时映射到 aria2 的 `referer`、`user-agent`、`out`、`header`（Cookie 作为 `Cookie:` 头）。
- 扩展交接：来源页、User-Agent（`navigator.userAgent`）、建议文件名放在 `mulee://` 交接链接里；**Cookie 绝不进链接**。需要 Cookie 时走 Native Messaging，新增消息类型 `downloadCookies`，仅在用户为该网站授权后读取（可选权限，按需申请，默认关）。
- 未带 UA 时默认用 Safari 的 UA 字符串（常量，随版本更新），不再用 `Mulee/0.1`。
- aria2 全局增加：`max-tries=5`、`retry-wait=5`、`lowest-speed-limit=1K`（配合 `max-tries` 自动重连）、`connect-timeout=30`、`timeout=60`。
- 任务持久化：带 Cookie 的任务，Cookie 只保存在钥匙串或 0600 文件里，任务历史 JSON 里不存明文。

### A2 磁盘保护容量（全局，所有引擎）
- 设置 `download.diskReserveGB`，默认 **10**，范围 1–500；开关 `download.diskReserveEnabled` 默认开。
- 监控所有正在写入的保存目录所在的卷（按卷去重），每 5 秒检查一次剩余空间（`volumeAvailableCapacityForImportantUsage`）。
- 剩余空间 ≤ 保护容量 + 2 GB：琥珀色提示「磁盘空间快到保护线」，不暂停。
- 剩余空间 ≤ 保护容量：**暂停写入该卷的所有任务**（HTTP、BT、电驴、视频、解压），状态显示「因磁盘空间不足已暂停」，发系统通知，菜单栏和主窗口顶部显示横幅：剩余多少、保护线多少、怎么办（清理磁盘 / 换保存目录 / 调低保护容量）。空间恢复到保护线 + 1 GB 以上时，**只自动恢复**因磁盘空间暂停的任务。
- 新建下载时，如果已知大小且「剩余 − 文件大小 < 保护容量」，在新建面板里提示并要求确认（D4）。
- BT 做种不写盘，不受影响。

### B1 系统通知
- `UNUserNotificationCenter`；设置 `general.notifyOnComplete`（默认开）、`general.notifyOnFailure`（默认开）、`general.notificationSound`（默认关）。
- 完成通知带动作「打开」「在访达中显示」；压缩包加「解压」（未开启自动解压时）。10 秒内完成多个任务合并为一条：「N 个下载已完成」。
- 磁盘保护、下完后动作倒计时也用通知。

### B2 下完后动作
- 设置 `general.whenAllDone`：`none`（默认）/ `sleep` / `shutdown` / `quit`。菜单栏面板和主窗口菜单可临时切换「本次下完后」。
- 计入范围：开启时正在下载或等待的任务 + 之后新加入的任务；做种、电驴长尾「等待来源」超过 24 小时的任务不算阻塞。
- 全部完成后 60 秒倒计时，期间显示可取消的面板和通知；新任务加入或用户操作则取消。
- 睡眠用 IOKit `IOPMSleepSystem`；关机通过 `NSAppleScript` 请求系统事件（首次需用户授权自动化），不用 sudo。

### B3 快捷指令与链接调用
- App Intents：「新建下载」（链接、保存目录可选，默认弹出确认面板）、「暂停全部」「继续全部」「获取下载状态」。
- `mulee://add?url=…` 只**预填**新建面板，不直接开始下载。

### C1 站点与分类规则
- 新增「下载规则」：条件 = 来源网站（域名通配）/ 扩展名列表 / 任务类型；结果 = 保存子目录、User-Agent、HTTP 线程数、单任务限速。内置扩展名分类：视频、音频、压缩包、文档、程序、镜像（默认只用于显示，开关 `download.sortIntoFolders` 默认关，开启后按分类放进子文件夹）。
- 规则引擎和解压密码规则共用匹配器。

### C2 未完成文件标记
- HTTP：先下到 `<保存目录>/.mulee-incomplete/<任务ID>/`，完成后原子移动到最终位置（同卷改名）；BT：libtorrent 未完成文件改名为 `<名字>.mulee`，完成后改回。设置 `download.markIncomplete` 默认开。
- 自动解压只在完成并改名后触发。
- 下载中的文件用 `NSProgress` 发布到文件 URL，Finder 图标显示进度。

### C3 标签与智能列表
- 任务可以加多个标签；侧边栏新增「智能列表」：卡住超过 1 小时、出错、今天完成、按标签。

### C4 文件跟踪
- 完成的任务保存文件书签（bookmark data）；文件被移走时自动更新路径，被删时标记「文件已不在」，不自动删记录。

### D1 智能粘贴
- 新建面板识别：多行链接、`cURL` 命令（含 `-H`、`-b`/`--cookie`、`-A`、`-e`、`--url`，支持单双引号与反斜杠续行，含 `$(`、反引号、`;`、`|` 的拒绝解析）、批量通配 `[1-10]` / `[01-10]` / `[a-z]`（单条展开上限 1000）、裸 40/64 位 hash（转磁力）。每行显示识别结果或不能下载的原因。cURL 解析出的头和 Cookie 进入 `DownloadRequestContext`。

### D2 BT 垃圾文件过滤
- 设置 `bt.skipJunkFiles` 默认开，规则列表 `bt.junkFilePatterns`（通配，可编辑），内置：`*.url`、`*.lnk`、`*padding_file*`、`_____padding_file_*`、`*.!ut`、常见广告 txt/html 文件名（如 `*最新地址*.txt`、`*广告*.txt`、`*.mht`）。添加时把匹配文件设为不下载，新建面板里显示「已跳过 N 个无用文件」，可手动勾回。

### D3 视频逐任务格式
- 新建面板对视频链接读取 yt-dlp 格式列表（`-J`），显示分辨率、编码、大小，标注「需要登录」；可选「跟随全局设置」（默认）或指定格式。按站点记住上次选择。

### D4 添加前检查
- 已知大小时检查剩余空间与保护容量（A2）。
- 重名：设置 `download.duplicateAction`：`rename`（默认，自动编号）/ `overwrite` / `ask`。
- 重复添加同一个种子：提示已存在；公开种子询问是否合并 tracker，私有种子不合并。

### D5 监视文件夹
- 设置 `bt.watchFolders`（列表，默认空）；用 FSEvents 监视新出现的 `.torrent` / `.magnet` 文本，自动加入（走新建确认或直接添加，设置 `bt.watchAutoStart` 默认 false = 弹确认）。处理后的文件移到 `.mulee-added` 子目录。

### D6 菜单栏拖放
- 菜单栏图标接受拖入的 .torrent 文件、链接文本，打开预填的新建面板。

### E1 慢速模式
- 设置 `network.slowModeDownloadMBps`（默认 1）、`network.slowModeUploadMBps`（默认 0.2）；菜单栏和主窗口工具栏一键切换；与按时段限速取较小值。
- `network.slowModeOnExpensive` 默认开：网络是个人热点（`NWPath.isExpensive`）或系统「低数据模式」（`isConstrained`）时自动进入慢速模式，界面说明原因。

### E2 链接过期换链
- HTTP 任务出错（401/403/404/410、内容变成网页）时，详情栏和通知给出原因和「换个链接继续」：粘贴或从浏览器扩展抓取新链接，校验文件大小（及 ETag 若有）一致后，以同一个文件续传；不一致则提示并要求确认从头下载。
- 错误文案讲人话：链接过期、需要登录、服务器把下载换成了网页、文件在服务器上变了。

### E3 下载校验
- 新建面板和任务详情可填 MD5 / SHA-1 / SHA-256；粘贴文本或同目录出现 `<文件名>.sha256` / `SHA256SUMS` 时自动识别。HTTP 用 aria2 `checksum`；其他类型完成后计算。结果显示在详情栏，不一致时提示并提供重新下载。

### E4 边下边播
- 视频文件（BT 文件、HTTP 视频、视频任务的成品）在详情栏和右键菜单提供「播放」：BT 先打开顺序下载和首尾块优先，缓冲到 20 MB 或 5% 后用默认播放器打开（IINA、VLC 优先，其次 QuickTime）。

### E5 任务回收站
- 删除任务记录（不删文件时）先进回收站，保留 30 天，可恢复；侧边栏「最近删除」。

### E6 队列与计划
- 计划：设置开始时间、结束时间、星期；到开始时间自动「全部继续」，到结束时间自动「全部暂停」。睡眠中用 `IOPMSchedulePowerEvent` 定时唤醒；没有唤醒权限时说明原因。

### F1 做种限制扩展
- 在分享率之外加：做种时长 `bt.seedTimeLimitMinutes`（默认 0=不限）、不活跃时长 `bt.seedInactiveLimitMinutes`（默认 0）；达到任一条件后动作沿用 `bt.seedingAction`（降速 / 停止），新增「删除任务（保留文件）」。私有种子可单独设最低做种时长 `bt.privateMinSeedMinutes`（默认 0），未达到前不执行任何动作。

### F2 BT 任务管理
- 移动存储位置（libtorrent `move_storage`，同名冲突询问）、重命名文件/文件夹、强制重新校验、强制宣告。

### F3 Tracker 管理
- 详情栏 tracker 列表：状态、上次结果、节点数；可编辑、删除、添加；连续失败的公共 tracker（来自订阅）自动停用 24 小时。

### F4 节点列表与封禁
- 详情栏节点列表：地址、客户端、进度、上下行速度、来源、连接类型；右键封禁 IP（持久化）；设置里可导入 IP 黑名单（P2P/DAT 格式）。

### F5 制作与导出种子
- 从文件或文件夹制作 .torrent（v1+v2 混合、私有标记、tracker 列表、分块大小自动）；任务右键「导出种子文件」。

### F6 速度曲线与统计
- 菜单栏面板和设置里显示最近 10 分钟 / 1 小时的速度曲线（下载、上传分开）；累计统计（总下载、总上传、各类型占比），本地保存。

## 不可回归
- 现有全部测试；隐私检查；翻译门禁。
- 视频登录状态交接、扩展链接交接的现有行为。
- 退出约 1 秒、进度不丢；fake-ip 下 BT 正常；三栏布局与工具栏。
- 不新增任何会把 Cookie、口令写进日志、URL、任务历史明文的路径。

## 后果
- 新增设置若干；SettingsModel、设置页各标签、新建面板、详情栏、菜单栏面板均有改动。
- mulee-torrentd 新增命令：做种时长条件、move_storage、rename、force_recheck、force_reannounce、tracker 编辑、peer 列表、IP 过滤、创建/导出种子。
- 扩展新增可选权限与 Native Messaging 消息类型。

## 裁决记录
- A1 aria2 子进程以 `umask 077` 启动，session 和日志从创建起就是 0600。
- A1 扩展交接 Cookie 沿用视频登录的文件交接通道：一次性 token 命名的 0600 文件（目录 0700），App 读取后立即删除，超过 60 秒的交接文件清理掉；`mulee://` 链接只带 token。不另建进程间通信。
- C1 规则里的 User-Agent、线程数、单任务限速只作用于 HTTP 任务；保存目录和分类对所有类型生效。
- D4 添加前的磁盘检查调用 `DiskReserveMonitor.requiresConfirmation(forKnownBytes:in:)`，读取失败时不拦截添加。
