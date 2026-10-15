# Mulee 图标规范

App 内图标**一律使用 SF Symbols**。唯一的自定义图标是菜单栏的 Mulee 标志（`MenuBarIcon`）。
代码里所有图标都通过 `MuleeSymbol` 枚举引用（`Mulee/DesignSystem/MuleeSymbol.swift`），**不允许在视图里直接写符号名字符串**。
单元测试会逐个检查这些符号名在系统里真实存在。

下载列表里每一行的文件图标，用系统根据扩展名给出的访达图标（`NSWorkspace.shared.icon(for:)`），和访达保持一致，不自己画。

## 侧边栏 · 按状态

| 项目 | 符号 | 枚举 |
|---|---|---|
| 全部 | `tray.full` | `.all` |
| 下载中 | `arrow.down.circle` | `.downloading` |
| 等待来源 | `hourglass` | `.waitingForSources` |
| 做种中 | `arrow.up.circle` | `.seeding` |
| 已完成 | `checkmark.circle` | `.completed` |

## 侧边栏 · 按类型（也用于任务类型标识、设置标签页）

| 类型 | 符号 | 枚举 |
|---|---|---|
| 网页 HTTP | `globe` | `.http` |
| BT / 磁力 | `point.3.connected.trianglepath.dotted` | `.bittorrent` |
| 电驴 ed2k | `antenna.radiowaves.left.and.right` | `.ed2k` |
| 视频 | `play.rectangle` | `.video` |

## 任务状态

| 状态 | 符号 | 颜色 | 枚举 |
|---|---|---|---|
| 下载中 | `arrow.down` | AccentColor | `.statusDownloading` |
| 等待来源 | `hourglass` | WaitColor | `.waitingForSources` |
| 做种中 | `arrow.up` | SuccessColor | `.statusSeeding` |
| 解压中 | `archivebox` | SuccessColor | `.statusExtracting` |
| 合并音视频 | `film.stack` | AccentColor | `.statusMerging` |
| 已暂停 | `pause.circle` | 次要文字色 | `.statusPaused` |
| 已完成 | `checkmark.circle.fill` | SuccessColor | `.statusCompleted` |
| 出错 | `exclamationmark.triangle.fill` | WaitColor | `.statusFailed` |

> 出错也用琥珀色，不用红色。

## 工具栏与操作

| 操作 | 符号 | 枚举 |
|---|---|---|
| 新建下载 / 新增规则 | `plus` | `.add` |
| 删除规则（列表下方的减号） | `minus` | `.remove` |
| 全部暂停 / 暂停 | `pause.fill` | `.pause` |
| 全部继续 / 继续 | `play.fill` | `.resume` |
| 搜索 | `magnifyingglass` | `.search` |
| 复制链接 / 复制规则 | `doc.on.doc` | `.copy` |
| 在访达中显示 | `folder` | `.revealInFinder` |
| 删除任务 | `trash` | `.delete` |
| 重新检测 / 重试 | `arrow.clockwise` | `.retry` |
| 显示/隐藏详情栏 | `sidebar.right` | `.inspector` |

## 网络状态

| 项目 | 符号 | 枚举 |
|---|---|---|
| 状态指示点 | `circle.fill`（按状态着色） | `.statusDot` |
| P2P 走代理警告 | `exclamationmark.shield.fill`（WaitColor） | `.proxyWarning` |
| Kad 网络 | `antenna.radiowaves.left.and.right` | `.ed2k` |
| 端口与连通性 | `network` | `.network` |

## 设置窗口标签页

| 标签 | 符号 | 枚举 |
|---|---|---|
| 通用 | `gearshape` | `.settingsGeneral` |
| 下载 | `arrow.down.circle` | `.downloading` |
| 网络 | `network` | `.network` |
| BT | `point.3.connected.trianglepath.dotted` | `.bittorrent` |
| 电驴 | `antenna.radiowaves.left.and.right` | `.ed2k` |
| 视频 | `play.rectangle` | `.video` |
| 解压 | `archivebox` | `.statusExtracting` |

## 解压规则的匹配方式

| 匹配方式 | 符号 | 枚举 |
|---|---|---|
| 来源网站 | `link` | `.ruleSourceSite` |
| 文件名前缀 | `doc.text` | `.ruleFilenamePrefix` |
| 文件名规则（正则） | `chevron.left.forwardslash.chevron.right` | `.ruleFilenameRegex` |
| 密码本 | `key` | `.rulePasswordBook` |

## 菜单栏

| 项目 | 资源 |
|---|---|
| 菜单栏图标 | 自定义 `MenuBarIcon`（模板图，18pt），右侧跟实时下载速度 |
| 防止睡眠 | `cup.and.heat.waves` → 枚举 `.preventSleep` |

## 规则

1. 新增图标先改这份文档，再改 `MuleeSymbol`，测试会自动覆盖新符号。
2. 只有图标的按钮必须带文字标签：`Button("暂停", systemImage: MuleeSymbol.pause.name, action: pause)`，需要时再加 `.labelStyle(.iconOnly)`。
3. **不要用带文字的符号**（例如 `textformat`）：中文系统下 SF Symbols 会把它本地化成汉字「格式」，失去图标意义。
4. 状态不能只靠颜色区分：状态符号本身就不一样，色盲用户也能分辨。
