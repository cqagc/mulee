# Mulee 品牌规范

## 标志

![App 图标](Brand/mulee-icon-1024.png)

**寓意**：字母 **M** 的两个尖顶是驴耳朵（向 eMule / aMule 致敬），中间向下的 V 是下载箭头，底部一条托盘线表示「落到你的磁盘上」。

| 文件 | 用途 |
|---|---|
| `Brand/mulee-icon.svg` | App 图标母版（1024 画布，macOS 标准 824 圆角矩形底板 + 投影） |
| `Brand/mulee-icon-1024.png` | 图标位图，用于 README、网站 |
| `Brand/mulee-mark.svg` | 标志本体（无底板，单色黑），菜单栏模板图和文档里使用 |
| `Brand/explore/` | 设计过程中淘汰的方向：A 驴耳+箭头（小尺寸像「¥」）、C 驴头（容易被看成兔子） |

App 内的图标资源由母版生成：

- `Mulee/Resources/Assets.xcassets/AppIcon.appiconset`：16 到 1024 全尺寸
- `MenuBarIcon.imageset`：18pt 矢量 PDF，模板渲染，菜单栏自动适配亮色和暗色
- `BrandMark.imageset`：64pt 矢量 PDF，模板渲染，用于「关于」窗口等

重新生成的命令见 `scripts/make-icons.sh`。

## 颜色

整个 App 只有一个强调色。其余两个是语义色，只用于表达状态。

| 资源名 | 亮色 | 暗色 | 用途 |
|---|---|---|---|
| `AccentColor` | `#2A7FE2` | `#5EA0F3` | 强调色：进行中、选中、主按钮 |
| `WaitColor` | `#D09844` | `#E0AD62` | 「需要耐心」：电驴等待来源、Low ID、代理警告。**不用红色吓人** |
| `SuccessColor` | `#46A962` | `#68C17E` | 完成、正常、做种、解压 |

图标底板渐变：`#3D8BF0` → `#2356C8`（自上而下）。

## 字体

只用系统字体（SF Pro / 苹方），等宽信息（哈希、规则、命令）用 SF Mono。不引入任何第三方字体。

## 语气

- 冷门资源下不动不算失败，文案要让人安心挂着：「等待来源 · 已挂 12 天」，不说「失败」「错误」。
- 不说教，不吓人，不用感叹号。
