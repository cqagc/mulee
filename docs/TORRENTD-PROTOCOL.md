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
{"id": 7, "result": {"id": "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c", "name": "Big Buck Bunny", "duplicate": false}}
{"id": 7, "error": {"code": "invalid_params", "message": "magnet 和 torrent_file 必须二选一"}}
```

事件（torrentd 主动推送，没有 `id`，有 `event`）：

```json
{"event": "ready", "version": "0.1.0", "libtorrent": "2.0.15", "listen_port": 6881}
{"event": "metadata_received", "id": "<torrent id>", "name": "..."}
{"event": "finished", "id": "<torrent id>"}
{"event": "torrent_error", "id": "<torrent id>", "message": "..."}
{"event": "fatal", "message": "..."}
```

事件只是提示，App 以 `list` 的结果为准；丢失事件不影响正确性。

错误码 `code`：`invalid_request`（JSON 无法解析或缺 method）、`unknown_method`、`invalid_params`、`not_found`（任务不存在）、`invalid_torrent`（种子文件或磁力链接无效）、`io_error`、`internal`。`message` 给开发者看，可以是英文。

数字一律是 JSON 整数（字节数、速度用字节 / 秒），比率用浮点；时间用 Unix 秒（整数）；路径是绝对 POSIX 路径。

**任务 id**：种子的 v1 info-hash，40 位小写十六进制；纯 v2 种子用 v2 info-hash 的前 40 位十六进制。磁力链接里的 btih 与此一致，所以 App 可以在添加前就知道 id。

## 方法

### `configure`

整体下发全局设置。启动后 App 会立即发一次，之后设置变化时整体重发。所有字段必填。

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

结果：`{"listen_port": <实际端口>}`。端口被占用时自动改用随机端口并在结果里如实返回。

### `add`

| 字段 | 类型 | 说明 |
|---|---|---|
| `magnet` | string? | 磁力链接（与 `torrent_file` 二选一） |
| `torrent_file` | string? | 本机 .torrent 文件路径；torrentd 读入后自己保存一份，原文件之后可以删 |
| `save_path` | string? | 保存目录；省略时用 `download_dir` |
| `paused` | bool? | 默认 false |
| `source` | string? | 用户粘贴的原始链接或文件路径，`list` 原样返回 |
| `file_priorities` | [int]? | 只对 `torrent_file` 有效：每个文件的优先级（0 = 不下载，4 = 默认），长度必须等于文件数，否则 `invalid_params` |

结果：`{"id": "...", "name": "...", "duplicate": bool}`。任务已存在时不报错，返回已有任务且 `duplicate: true`（磁力链接新带来的 tracker 合并进去）。

### `pause` / `resume`

参数 `{"id": "..."}`，结果 `{}`。`pause` 是「用户暂停」，会关闭 libtorrent 的自动管理（auto_managed），`resume` 恢复自动管理并继续。对已暂停 / 已在运行的任务重复调用不报错。

### `remove`

参数 `{"id": "...", "delete_files": bool}`，结果 `{}`。`delete_files` 为 true 时删除已下载的数据和未完成的部分文件（libtorrent `delete_files`）；同时删除该任务的 resume 和元数据文件。

### `list`

参数 `{}`。结果 `{"torrents": [ ... ]}`，每项：

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

### `set_file_priorities`

参数 `{"id": "...", "priorities": [4, 0, 4]}`，长度必须等于文件数，否则 `invalid_params`。结果 `{}`。

### `set_upload_limit`

参数 `{"id": "...", "limit": <字节/秒，0 不限>}`。结果 `{}`。用于做种策略「到 1:1 后降速」。

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
- `<state-dir>/meta/<id>.json`：Mulee 自己的附加信息 `{"source": ..., "added_at": ..., "completed_at": ...}`。
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

做种策略在 App 端执行（每次轮询）：`ratio >= 1` 且不是「私有种子且设置为私有种子不按分享率停」时，设置为「停止」则发 `pause`，设置为「降速」则发 `set_upload_limit` 51200（只在当前值不同时发）。
