# mulee-torrentd 协议

`mulee-torrentd` 是 Mulee 的 BT / 磁力下载辅助进程：一个静态链接 libtorrent-rasterbar 2.0 和 OpenSSL 的 C++ 可执行文件，放在 `Mulee.app/Contents/Helpers/mulee-torrentd`。App 端由 `TorrentEngine`（MuleeCore）启动和监督。

进程名必须保持 `mulee-torrentd`：用户的代理软件（Stash / Clash）按进程名把 P2P 流量设为直连，改名会让 BT 流量走代理。

## 启动与生命周期

```
mulee-torrentd --state-dir <目录>
```

- `--state-dir`：会话状态目录（App 传 `~/Library/Application Support/Mulee/torrent`）。不存在则创建，权限 0700。
- 通信走 **stdin / stdout，每行一个 UTF-8 JSON 对象**（JSON Lines，`\n` 结尾，行内不得有裸换行）。stdout 只写协议消息；日志写 stderr，并追加到 `<state-dir>/torrentd.log`（超过 5MB 时轮转一份 `.1`）。
- 启动后先恢复 `<state-dir>/resume/` 里的全部任务，然后输出 `ready` 事件。App 在收到 `ready` 之前不发请求（超时 15 秒视为启动失败）。
- **stdin 读到 EOF（父进程退出或崩溃）= 优雅退出**：保存所有任务的 resume data（最多等 10 秒），然后退出码 0。`shutdown` 请求效果相同，先回复再退出。
- 收到 SIGTERM / SIGINT 同样优雅退出；SIGPIPE 忽略。
- 同一个 `--state-dir` 只允许一个实例：用 `<state-dir>/lock` 加 `flock`，拿不到锁时输出 `{"event":"fatal","message":"..."}` 并以退出码 2 退出。

## 消息格式

请求（App → torrentd）：

```json
{"id": 7, "method": "add", "params": {"magnet": "magnet:?xt=urn:btih:..."}}
```

响应（torrentd → App），`id` 与请求相同，二选一：

```json
{"id": 7, "result": {"id": "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c", "name": "Mulee fixture", "duplicate": false, "skipped_files": []}}
{"id": 7, "error": {"code": "invalid_params", "message": "magnet 和 torrent_file 必须二选一"}}
```

事件（torrentd 主动推送，没有 `id`，有 `event`）：

```json
{"event": "ready", "version": "0.1.0", "libtorrent": "2.0.15", "listen_port": 6881}
{"event": "metadata_received", "id": "<torrent id>", "name": "...", "skipped_files": []}
{"event": "finished", "id": "<torrent id>"}
{"event": "torrent_error", "id": "<torrent id>", "message": "..."}
{"event": "fatal", "message": "..."}
```

下载事件只是提示，App 以 `list` 的结果为准；制作种子的 `create_progress` 用于显示进度，最终状态以 `create_torrent` 响应为准。

错误码 `code`：`invalid_request`（JSON 无法解析或缺 method）、`unknown_method`、`invalid_params`、`not_found`（任务不存在）、`invalid_torrent`（种子文件或磁力链接无效）、`io_error`、`metadata_pending`（元数据尚未取得）、`private_torrent`（禁止向私有种子自动追加 tracker）、`tracker_limit`、`conflict`（目标已有同名文件或制作任务正在运行）、`cancelled`（制作已取消）、`internal`。`message` 给开发者看，可以是英文。

数字一律是 JSON 整数（字节数、速度用字节 / 秒），比率用浮点；时间用 Unix 秒（整数）；路径是绝对 POSIX 路径。

**任务 id**：种子的 v1 info-hash，40 位小写十六进制；纯 v2 种子用 v2 info-hash 的前 40 位十六进制。磁力链接里的 btih 与此一致，所以 App 可以在添加前就知道 id。

## 方法

### `configure`

整体下发全局设置。启动后 App 会立即发一次，之后设置变化时整体重发。除标记可选的字段外均必填。

| 字段 | 类型 | 说明 |
|---|---|---|
| `download_dir` | string | 默认保存目录 |
| `listen_port` | int | 监听端口（TCP + uTP 同端口）。0 表示随机 |
| `download_limit` | int | 全局下载限速，0 不限 |
| `upload_limit` | int | 全局上传限速，0 不限 |
| `max_active_downloads` | int | 同时下载的种子数 |
| `max_active_seeds` | int | 同时做种的种子数 |
| `dht` | bool | DHT |
| `lsd` | bool | 本地发现 |
| `port_mapping` | bool | UPnP + NAT-PMP |
| `encryption` | string | `"prefer"`（默认，允许明文）/ `"require"` / `"disable"` |
| `skip_junk_files` | bool? | 默认 true；添加任务时匹配文件名并设置优先级 0 |
| `junk_file_patterns` | [string]? | 通配列表，最多 256 项、每项 1–1024 字节，大小写不敏感 |
| `ip_blocklist_path` | string? | P2P / DAT 文件绝对路径；空串清除导入范围，保留手动封禁；省略保留当前导入范围 |

结果：`{"listen_port": <实际端口>}`。端口被占用时自动改用随机端口并在结果里如实返回。

### `add`

| 字段 | 类型 | 说明 |
|---|---|---|
| `magnet` | string? | 磁力链接（与 `torrent_file` 二选一） |
| `torrent_file` | string? | 本机 .torrent 文件路径；torrentd 读入后自己保存一份，原文件之后可以删 |
| `save_path` | string? | 保存目录；省略时用 `download_dir` |
| `paused` | bool? | 默认 false |
| `mark_incomplete` | bool? | 默认 true，只影响新任务；未完成文件用 `.mulee` 后缀，逐文件全部 piece 校验后由 `rename_file` 改回，映射持久化到 meta/resume；旧任务缺此字段保持原路径 |
| `source` | string? | 用户粘贴的原始链接或文件路径，`list` 原样返回 |
| `file_priorities` | [int]? | 只对 `torrent_file` 有效：每个文件的优先级（0 = 不下载，4 = 默认），长度必须等于文件数，否则 `invalid_params` |

结果：`{"id": "...", "name": "...", "duplicate": bool, "skipped_files": [{"index": 1, "path": "目录/广告.txt"}]}`。任务已存在时不报错，返回已有任务且 `duplicate: true`（公开种子的磁力链接新带来的 tracker 合并进去；私有或尚无元数据时返回明确错误）。

默认通配清单：`*.url`、`*.lnk`、`*padding_file*`、`_____padding_file_*`、`*.!ut`、`*最新地址*.txt`、`*广告*.txt`、`*最新地址*.html`、`*广告*.html`、`*.mht`。显式 `file_priorities` 表示用户已确认的选择，优先于自动过滤；之后也可通过 `set_file_priorities` 勾回。磁力任务先返回空的 `skipped_files`，取得元数据后按添加时的规则过滤，`metadata_received` 事件附带 `skipped_files`，且 `list` 持续返回该结果。

### `pause` / `resume`

参数 `{"id": "..."}`，结果 `{}`。`pause` 是「用户暂停」，会关闭 libtorrent 的自动管理（auto_managed），`resume` 恢复自动管理并继续。对已暂停 / 已在运行的任务重复调用不报错。

### `remove`

参数 `{"id": "...", "delete_files": bool}`，结果 `{}`。`delete_files` 为 true 时删除已下载的数据和未完成的部分文件（libtorrent `delete_files`）；同时删除该任务的 resume 和元数据文件。

### `list`

参数 `{}`。结果 `{"torrents": [ ... ]}`，每项：

未完成文件改名失败只影响该任务：仍返回它和其他任务的快照，该项 `state` 为 `error`、`is_finished` 为 false，`error` 为 `conflict`（同名冲突）或 `io_error`（磁盘操作失败）。后续 `list` 会重试改名，成功后恢复正常字段。

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | string | 任务 id |
| `name` | string | 种子名；还没拿到元数据时用磁力链接的 dn，没有 dn 时用 id |
| `save_path` | string | 保存目录 |
| `content_path` | string? | 单文件种子是文件完整路径，多文件种子是顶层文件夹路径；没有元数据时为 null |
| `has_metadata` | bool | |
| `state` | string | 见下表 |
| `paused` | bool | 用户暂停（或被做种策略停止） |
| `total_wanted` | int | 选中文件的总字节数；没有元数据时为 0 |
| `total_wanted_done` | int | 选中文件已完成的字节数 |
| `progress` | double | 0...1 |
| `download_rate` | int | 字节 / 秒（payload） |
| `upload_rate` | int | 字节 / 秒（payload） |
| `all_time_download` | int | 累计下载字节（跨重启保留） |
| `all_time_upload` | int | 累计上传字节（跨重启保留） |
| `ratio` | double | `all_time_upload / max(total_wanted_done, 1)` |
| `num_peers` | int | 已连接的 peer 数 |
| `num_seeds` | int | 已连接的做种者数 |
| `list_peers` | int | tracker / DHT 报告的 peer 总数（估计） |
| `list_seeds` | int | 同上，做种者 |
| `file_count` | int | 文件数；没有元数据时为 0 |
| `selected_file_count` | int | 优先级非 0 的文件数 |
| `is_private` | bool | 私有种子（info 里带 private 标记） |
| `upload_limit` | int | 该任务自己的上传限速，0 不限 |
| `error` | string? | libtorrent 报告的错误（英文原文），没有为 null |
| `source` | string? | `add` 时传入的 `source` |
| `added_at` | int | Unix 秒 |
| `completed_at` | int? | 选中文件全部完成的时间；未完成为 null |
| `eta` | int? | 预计剩余秒数；无法估计为 null |
| `is_finished` | bool | 所选内容全部完成，且不在校验、元数据或错误状态 |
| `seed_time_seconds` | int | libtorrent 累计 finished_duration，计入选择性下载，暂停时间不计入 |
| `seed_inactive_seconds` | int | 没有 payload 活动的累计活跃做种秒数，暂停不增加，发生上传/下载或重新变为未完成时清零 |
| `skipped_files` | [object] | 添加时自动跳过的 index/path，保留供界面展示 |

`state` 取值：

| state | 含义 |
|---|---|
| `checking` | 校验已有数据（含启动时恢复） |
| `metadata` | 磁力链接正在获取元数据 |
| `downloading` | 下载中（含排队等待自动管理的空位时，此时 `queued` 为 true，见下） |
| `seeding` | 选中文件已全部完成，正在做种 |
| `finished` | 选中文件已全部完成，没有在做种（例如被暂停） |
| `error` | 出错（磁盘满、权限等），见 `error` |

另有布尔字段 `queued`：自动管理排队中（未被分配活动名额）。

### `files`

参数 `{"id": "..."}`。没有元数据时返回空数组。结果 `{"files": [{"index": 0, "path": "相对路径", "size": 123, "done": 45, "priority": 4}]}`。`priority` 0 = 不下载，1–7 = 下载（libtorrent 优先级，默认 4）。

`done` 包含尚未完成 piece 中已下载的块，不再按完整 piece 粗化。`contiguous_done` 仍仅累计从文件头连续已校验的 piece；播放器必须使用此字段，不能用 `done` 代替。完成改名同样要等相关 piece 校验通过。

### `magnet_uri`

参数 `{"id": "..."}`，结果 `{"uri": "magnet:?xt=..."}`。用 libtorrent `make_magnet_uri` 从任务生成，包含名称和 tracker；缺少元数据返回 `metadata_pending`，不存在返回 `not_found`。

### `set_task_limits`

参数 `{"id": "...", "download_limit": 0, "upload_limit": 0}`，结果 `{}`。两个限速必填，整数范围 0–2147483647，单位字节/秒，0 表示不限。原子校验后分别调用 `set_download_limit` / `set_upload_limit`。

`list` 增加 `user_download_limit`、`user_upload_limit`（用户值）、`policy_upload_limit`（做种策略值）、`download_limit`（实际任务下载限速）；既有 `upload_limit` 仍为实际上传限速。用户限速和做种策略限速分别持久化，上传生效值取两个非零值的最小值；均为 0 时不限。全局带宽限制仍然生效。

Swift API：`TorrentEngine.magnetURI(_:) async throws -> String`、`TorrentEngine.setTaskLimits(id:download:upload:) async throws`；`TorrentTaskInfo` 暴露 `userDownloadLimit` / `userUploadLimit`。本轮不增加单任务限速界面。

### `set_file_priorities`

参数 `{"id": "...", "priorities": [4, 0, 4]}`，长度必须等于文件数，否则 `invalid_params`。结果 `{}`。

### `set_upload_limit`

参数 `{"id": "...", "limit": <字节/秒，0 不限>}`。结果 `{}`。用于做种策略「到 1:1 后降速」。它只设置策略值，不覆盖用户值；0 清除策略限速。

### `move_storage`

参数 `{"id": "...", "path": "/tmp/target", "conflict": "fail"}`，结果 `{}`。`conflict` 必填：`fail` 遇到目标同名文件返回 `conflict`（Swift 映射为 `EngineError.rpc(code: 11, ...)`），由调用方询问用户后重试；`keep` 保留目标文件并重新校验；`overwrite` 覆盖目标文件。映射到 libtorrent `fail_if_exist` / `dont_replace` / `always_replace_files`。等磁盘完成通知才回复，磁盘失败返回 `io_error`；操作等待上限 300 秒，超时后应先回读状态。`fail` 沿用 libtorrent 的预检查语义，不承诺阻止其他进程在检查后的竞争写入。

### `rename_file`

参数 `{"id": "...", "path": "目录/原名.bin", "new_path": "目录/新名.bin"}`，结果 `{}`。两个路径均相对保存目录，禁止绝对路径及 `.` / `..` 分量。匹配单文件或目录前缀，逐个等待 libtorrent 重命名确认；不存在返回 `not_found`，目标冲突返回 `conflict`。目录含多个文件时若中途磁盘失败，已完成的重命名不会回滚，调用方应重新读取 `files`。

冲突检查同时覆盖最终名和实际存储名（未完成时带 `.mulee` 后缀），并检查磁盘路径及同一种子的其他文件映射；未在磁盘分配的文件映射也不能被占用。

### `force_recheck` / `force_reannounce`

参数 `{"id": "..."}`，结果 `{}`。分别排入强制校验、立即重新宣告；宣告忽略 tracker 最小间隔。校验进度由 `list` 读取，结果回复表示指令已提交。

### `trackers` / `set_trackers` / `add_trackers`

`trackers` 参数 `{"id": "..."}`，结果：

```json
{
  "trackers": [
    {
      "url": "https://tracker.invalid/announce",
      "tier": 0,
      "status": "pending",
      "last_result": "",
      "peers": 0,
      "subscription": true,
      "disabled_until": 0
    }
  ]
}
```

`status` 为 `pending` / `working` / `failed` / `disabled`。`peers` 为最后一次宣告返回的节点数；尚无响应时为 0。`disabled_until` 为 Unix 秒，0 表示启用。

`set_trackers` 参数 `{"id": "...", "trackers": [{"url": "https://tracker.invalid/announce", "tier": 0, "subscription": false}]}`，结果 `{}`。完整替换列表，实现添加、编辑和删除，空列表清空；最多 50 个唯一 URL，tier 为 0–255。支持 HTTP/HTTPS/UDP，整批校验通过才修改。未编辑的订阅 URL 保留失败计数和停用期限；改为手动条目可解除订阅停用。

`add_trackers` 参数 `{"id": "...", "urls": ["https://tracker.invalid/announce"], "subscription": true}`，结果 `{"added": 1, "total": 1}`。`subscription` 默认 false，公共列表自动追加时设为 true；去重追加到独立 tier，最多 50 个（含停用条目）。尚无元数据返回 `metadata_pending`；私有种子返回 `private_torrent`。重复追加不会绕过停用期限。

来自订阅的公共 tracker 连续失败 **3 次**后从 libtorrent 活动列表移除 **24 小时**，成功响应清零计数；其他 tracker 和私有种子不会自动停用。到期自动放回原 tier。停用记录、计数、最后结果和节点数随任务元数据持久化。

### `peers` / `ban_ip` / `import_ip_blocklist`

`peers` 参数 `{"id": "..."}`，结果 `{"peers": [{"address": "192.0.2.10", "port": 6881, "client": "Mulee", "progress": 0.5, "download_rate": 1024, "upload_rate": 512, "sources": ["tracker", "pex"], "connection": "tcp"}]}`。`sources` 可含 tracker/dht/pex/lsd/incoming；`connection` 为 tcp/utp。

`ban_ip` 参数 `{"ip": "192.0.2.10"}`，结果 `{}`，支持 IPv4/IPv6，重复封禁幂等。使用 libtorrent `ip_filter` 断开和阻止连接，保留原有 peer class 带宽过滤。

`import_ip_blocklist` 参数 `{"path": "/tmp/fixture.dat"}`，结果 `{"blocked_ranges": 2}`。读取不超过 64 MiB 的 UTF-8 P2P 文本 `名称:起始IP-结束IP` 或 DAT `起始IP - 结束IP , level , 名称`；空行、`#` / `;` 注释忽略，DAT 仅 level < 127 屏蔽。地址或区间有误整批拒绝，保留旧规则。导入替换之前导入的范围，保留手动封禁。规则跨重启恢复。

### `create_torrent` / `export_torrent`

`create_torrent` 参数 `{"job_id": "<唯一制作任务标识>", "path": "/tmp/source", "output": "/tmp/fixture.torrent", "private": false, "trackers": ["https://tracker.invalid/announce"], "comment": "可选备注"}`。输入为文件或目录；制作 v1+v2 混合种子，分块大小自动，每个 tracker 单独 tier；最多 50 个 tracker。不允许符号链接，输出已存在返回 `conflict`。计算文件哈希后原子写入，结果 `{"path": "/tmp/fixture.torrent", "id": "<info hash>"}`。

`job_id` 为 1–128 字节的字符串，Swift 端使用 UUID；兼容旧调用时可省略，默认使用请求 `id` 的 JSON 表示。同一时间只允许一个制作任务，重复创建返回 `conflict`。哈希在工作线程执行，不阻塞其他协议命令。哈希每完成一个分块检查取消状态；进度通知最多每 200 ms 一次：

```json
{"event": "create_progress", "job_id": "<制作任务标识>", "completed_pieces": 20, "total_pieces": 100, "processed_bytes": 10485760, "total_bytes": 52428800}
```

百分比为 `completed_pieces / total_pieces`；字节数包含 v1+v2 混合种子的对齐填充。节流可能省略最后一次进度事件，成功响应表示制作完成。

`export_torrent` 参数 `{"id": "...", "output": "/tmp/export.torrent"}`，结果同上。从 resume data 导出，保留 info hash 和 v2 piece layers，以及当前启用的 tracker 列表。磁力未取得元数据返回 `metadata_pending`；v2 尚未取得完整 piece layers 时返回 `io_error`，待哈希可用后重试。已有输出返回 `conflict`。

### `cancel_create`

参数 `{"job_id": "<制作任务标识>"}`，结果 `{"cancelled": true}` 表示已请求中止；不存在或已完成返回 `{"cancelled": false}`。取消后，原 `create_torrent` 请求返回错误码 `cancelled`，表示哈希线程已停止，不会发布输出。取消与最终原子写入互斥，已有目标文件不会因取消被删除。App 等原请求结束后清理制作临时目录。`shutdown`、stdin EOF 和进程终止同样中止正在制作的任务。

### `session_status`

参数 `{}`。结果：

| 字段 | 类型 | 说明 |
|---|---|---|
| `listen_port` | int | 实际监听端口 |
| `dht_nodes` | int | DHT 路由表节点数 |
| `has_incoming_connections` | bool | 自启动以来是否有过从外部连入的连接（判断端口能否从外部连入） |
| `download_rate` | int | 会话总下载速度 |
| `upload_rate` | int | 会话总上传速度 |
| `external_address` | string? | libtorrent 观测到的外部地址（来自 tracker / peer），未知为 null |

### `shutdown`

参数 `{}`。回复 `{}` 后保存 resume data 并退出（退出码 0）。

## 持久化

- `<state-dir>/resume/<id>.resume`：libtorrent `write_resume_data_buf` 的结果（含元数据、tracker、文件优先级、累计上传下载、暂停状态）。任务状态变化后 30 秒内、以及退出时保存；先写临时文件再原子改名。
- `<state-dir>/meta/<id>.json`：Mulee 自己的附加信息（来源、添加/完成时间、下载模式、垃圾过滤待处理状态及结果、tracker 失败和停用记录、不活跃做种计数）。
- `<state-dir>/ip-filters.json`：手动封禁 `banned` 与导入范围 `imported`，以 0600 权限原子保存；不与 peer class 规则共用。
- 启动时读到损坏的 resume 文件：跳过并移到 `<state-dir>/broken/`，写日志，不影响其他任务。

## 默认的 libtorrent 设置

- `user_agent` / peer 指纹：`Mulee/<版本> libtorrent/2.0.15`，peer id 前缀 `-MU0100-`（版本号 0.1.0.0）。
- 启用 TCP 和 uTP；`enable_incoming_utp`、`enable_outgoing_utp` 为 true。
- `alert_mask`：status、error、storage、tracker 中与上述事件和 resume data 相关的类别；不要开 peer / debug 类别（量太大）。
- 磁盘 I/O 用 libtorrent 2.0 默认的 mmap 后端。
- 不内置任何 tracker 列表，不做任何「加速」或客户端伪装。

## App 端的映射（TorrentEngine）

| torrentd | Mulee `TaskStatus` |
|---|---|
| `paused` 且未完成 | `paused` |
| `paused` 且已完成（`finished` / 做种被策略停止） | `completed` |
| `checking`、`metadata`、`downloading`（`queued` 为 false） | `downloading` |
| `downloading` 且 `queued` 为 true | `queued` |
| `seeding` | `seeding` |
| `finished` 且未暂停 | `completed` |
| `error` | `failed` |

做种策略仍在 Swift `TorrentEngine.snapshots()` 每次轮询时执行。必须 `has_metadata && is_finished`，状态为 seeding/finished，所选文件数和所选字节数均大于 0，所选内容全部完成，才允许动作；恢复校验和扩大文件选择期间不触发。

新增设置及默认值：`bt.skipJunkFiles=true`、`bt.junkFilePatterns=上述内置清单`、`bt.seedTimeLimitMinutes=0`、`bt.seedInactiveLimitMinutes=0`、`bt.privateMinSeedMinutes=0`、`bt.ipBlocklistPath=""`。三个时长键单位为分钟，0 表示不限/无最低要求；时间条件由 Swift 执行，不作为 daemon configure 字段。

分享率达到 1（私有种子的 ratio 豁免只影响该条件）、做种时长达到非零上限、不活跃时长达到非零上限，任一满足即可触发。私有种子未达到最低做种时长之前，所有动作均不触发。`bt.seedingAction` 保留 stop/throttle，新增 remove：分别发 `pause`、`set_upload_limit` 51200、`remove(delete_files=false)`。删除后的任务从快照排除，并通过 `consumePolicyRemovals()` 交给 `BitTorrentController` 同步移除 App 记录。

Swift API：`TorrentEngineSettings.isJunkFile(path:)` 与 daemon 使用相同通配规则，供添加面板预选；`addWithResult` 返回 `TorrentdAddResult`（含 skippedFiles），`skippedFiles` 可读取磁力过滤结果；`moveStorage`、`renameFile`、`forceRecheck`、`forceReannounce`、`trackers`、`setTrackers`、`peers`、`banIP`、`importIPBlocklist`、`createTorrent`、`exportTorrent` 与上述命令对应。既有 add 返回任务 ID 的语义保持不变。

### `set_streaming`

参数 `{"id": "...", "file_index": 0, "enabled": true}`。要求元数据已取得且索引指向非 padding 文件；错误分别为 `metadata_pending` / `invalid_params`。

开启时将该文件设为最高文件优先级（取消或完成时恢复原优先级），启用顺序下载，并只对该文件的首尾各 2% 字节涉及的 piece 设置优先 deadline（至少各一个 piece，重叠去重）；其他未选择文件保持跳过。状态持久化，取消（`enabled: false`）或整个任务完成时清除流式 deadline，并关闭顺序下载和首尾优先。`set_download_mode` 原有语义保持不变。

结果 `{"file_index": 0, "priority_pieces": [0, 1, 98, 99]}`，数组是实际设置 deadline 的 piece 索引，取消时为空。

`files` 每项增加两个字段：

- `storage_path`：实际存储的种子内相对路径，可能含 `.mulee` 后缀；`path` 始终是无标记的逻辑路径。
- `contiguous_done`：从文件开头起连续、已通过 piece 校验的字节数。`done` 包含未完成 piece 中已下载的块，不能代替 `contiguous_done`，也不能用稀疏文件的大小推算可播放数据。

App 在连续开头达到 `min(20_000_000, ceil(size * 0.05))` 字节后打开播放器，缓冲期间可取消。HTTP 分段下载尚无可靠的连续开头判定，只在成品完成后开放播放。下载目录中的 `.mulee-incomplete/<任务 UUID>/` 属于 HTTP 引擎，不属于此辅助进程协议。

## 第二轮 B2/B3：原种子与 IP 黑名单订阅

- `bt.trashTorrentAfterAdd=false`：仅在从访达打开或拖入的本地 .torrent 添加成功后，调用 `FileManager.trashItem`。取消、添加失败、粘贴路径和远程链接不回收；监视文件夹沿用 `.mulee-added`。
- `bt.ipBlocklistURL=""`：空值关闭订阅；启动检查上次尝试时间，非空时每 7 天更新。URLSession 流式下载，下载内容与 gzip 解压后的内容均限制为 50 MiB。下载到临时文件，经 torrentd 同一 P2P/DAT 解析器校验成功后原子替换独立缓存；失败保留缓存，设置页显示最后成功时间与上次结果。
- `import_ip_blocklist` 新增可选 `validate_only`（默认 false）。true 时只解析并返回 `blocked_ranges`，不改变过滤器或持久化状态。
- `configure` 新增可选 `ip_blocklist_url_path`：本地订阅缓存路径，空字符串清除订阅过滤器。不改变 `ip_blocklist_path` 的本地导入语义；两者与手动封禁地址合并。未传字段保留既有对应过滤器。

本轮新增界面文案（中文原文，翻译由主控统一补齐）：

- 复制磁力链接
- 黑名单网址
- 每 7 天更新一次，支持 gzip；与本地名单合并，更新失败时保留旧名单。
- 上次更新
- 原种子文件
- 添加成功后将原种子移到废纸篓
- 仅处理从访达打开或拖入的种子；监视文件夹仍移到 .mulee-added。
- 黑名单已更新，将与本地名单合并。
- 黑名单更新失败，已保留旧名单。请检查网址、网络和文件格式。
- 任务已添加，但原种子未能移到废纸篓。请检查文件访问权限。
