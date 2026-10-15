# Mulee 图标规范

App 内操作与状态图标**一律使用 SF Symbols**。自定义图形包括菜单栏 Mulee 标志（`MenuBarIcon`）和下述文件类型图标的圆角方块；文件类别图形除 PDF 粗体文字外也使用 SF Symbols。
代码里所有图标都通过 `MuleeSymbol` 枚举引用（`Mulee/DesignSystem/MuleeSymbol.swift`），**不允许在视图里直接写符号名字符串**。
单元测试会逐个检查这些符号名在系统里真实存在。

下载列表和详情头部统一使用 `FileTypeIcon`，完全取代访达系统文件图标。

## 文件类型图标

采用设计方向 **1b 圆角方块**，以 64pt 为母版：内缩 7pt、边长 50pt、连续圆角 13pt、描边 2.5pt，其余尺寸等比缩放。类别图形约为方块边长的 45%；PDF 用粗体文字，不使用产品商标字母或带本地化文字的符号。

- 下载中 / queued / paused：虚线描边、浅底，稍深浅色按文件进度从下向上填充，裁剪在圆角方块内；图形使用中等深度类别色。
- 已完成 / extracting / postProcessing / seeding：文件已落盘，使用高饱和实心类别色与白色图形。
- failed / waitingForSources：沿用下载中样式与进度，全部统一为色相 75 的琥珀色（WaitColor 家族）。
- engineUnavailable：沿用虚线和进度，统一基准色相 255、色度乘以 0.15，显示近中性灰。
- 进度高度与虚实、颜色变化平滑过渡；开启「减少动态效果」时直接切换。列表图标对 VoiceOver 隐藏；独立图标朗读「类别 · 状态」。

### OKLCH 颜色公式

由 `OKLCHColor` 完成 OKLCH → OKLab → 线性 sRGB → sRGB 转换，超色域分量裁剪到 0...1；用 `NSColor` 动态 provider 根据外观取值。此公式是通用颜色来源规则的明确例外，不在代码中写十六进制颜色。

| 用途 | 亮色 L / C | 暗色 L / C |
|---|---|---|
| 描边 | .70 / .11 | .60 / .11 |
| 底 | .975 / .015 | .27 / .015 |
| 进度填充 | .89 / .07 | .40 / .07 |
| 下载中图形 | .55 / .13 | .80 / .13 |
| 完成块 | .60 / .17 | .66 / .17 |
| 完成角标（更深） | .48 / .17 | .52 / .17 |

同一状态只改变色相；文本与代码、安装包、其他的 C 乘以 0.15（基准色相 255）。需要注意时统一使用完整色度的琥珀色。引擎未接入时，所有类别统一使用基准色相 255，C 乘以 0.15。

### 类别与图形

| 类别 | 色相 | 符号 / 文字 | 代表扩展名 |
|---|---|---|---|
| PDF | 25 | 粗体 `PDF` | pdf |
| 演示文稿 | 50 | `rectangle.on.rectangle` | ppt, pptx, key, odp |
| 电子书 | 105 | `book.closed.fill` | epub, mobi, azw3, djvu |
| 表格 | 150 | `tablecells.fill` | xls, xlsx, numbers, csv, ods |
| 图片 | 175 | `photo` | jpg, png, heic, webp, raw |
| 压缩包 | 200 | `doc.zipper` | zip, rar, 7z, tar, gz, bz2, xz, zst, 001, part1.rar, z01 |
| 文件夹 | 225 | `folder.fill` | BT 多文件任务，或 BT 无扩展名 |
| 文字文档 | 250 | `doc.text.fill` | doc, docx, pages, rtf, odt |
| 光盘镜像 | 275 | `opticaldisc.fill` | iso, img, bin, cue, mdf, mds, nrg, ccd |
| 视频 | 300 | `play.fill` | mp4, mkv, webm, flv, rmvb, ts；视频任务无扩展名 |
| 音频 | 340 | `music.note` | mp3, flac, ape, m4a, opus |
| 文本与代码 | 中性 | `chevron.left.forwardslash.chevron.right` | txt, md, swift, json, py, tsx |
| 安装包 | 中性 | `shippingbox.fill` | dmg, pkg, exe, msi, apk, app |
| 其他 | 中性 | `doc.fill` | 未知扩展名或普通任务无扩展名 |

类别色相避开 60–95 琥珀区间。`.ts` 按视频传输流处理，`.dmg` 按安装包处理。视频与代码符号复用枚举中的 `.resume` 与 `.ruleFilenameRegex`，避免重复符号名。

### 格式角标与尺寸

视频、音频、压缩包、光盘镜像、图片、电子书在 **≥ 48pt** 且扩展名非空时，于右下角显示最多 4 字符的大写扩展名；其余类别和 < 48pt 不显示。角标白字，下载中用描边色作底，完成后用更深的类别色作底；外描边镂空透出真实背景，使其在窗口底色和详情栏材质上都与背景同色，并与方块分离。

| 画布尺寸 | 方块边长 | 圆角 | 描边 | dash / gap |
|---|---|---|---|---|
| 64pt | 50 | 13 | 2.5 | 4.5 / 3.5 |
| 32pt（列表） | 25 | 6.5 | 1.25 | 2.5 / 2 |
| 16pt | 12.5 | 3.25 | .625 | 1.5 / 1.25 |

≤ 16pt 以 16pt 虚线参数缩放，16–32pt 以 32pt 参数缩放，> 32pt 以 64pt 参数缩放。详情头部使用 64pt。Debug 启动参数 `-MuleeShowIconGallery YES` 自动打开亮暗对照窗口，包含全部类别的四种状态和 32pt / 16pt 样例。

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
