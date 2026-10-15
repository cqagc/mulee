# Mulee 开发约定

写代码前先读这份。新代码不符合这里的约定，会在评审时退回。

## 工程

- 工程由 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 从 `project.yml` 生成，`Mulee.xcodeproj` 不进仓库。改了工程结构就改 `project.yml`，然后运行 `xcodegen generate`。
- 构建：`xcodegen generate && xcodebuild -project Mulee.xcodeproj -scheme Mulee -destination 'platform=macOS' build`
- 测试：`swift test --package-path Packages/MuleeCore`（核心逻辑），`xcodebuild ... test`（App 层）
- 只支持 Apple Silicon、macOS 26 及以上。Swift 6，严格并发检查。
- App target 默认 MainActor 隔离（`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`）；`MuleeCore` 包不是，里面的类型要自己保证 `Sendable`。

## 目录

```
Mulee/                      App target
  App/                      入口与全局状态
  DesignSystem/             MuleeSymbol（图标）、Theme（颜色、间距等常量）
  Features/<功能>/          按功能分目录：MainWindow、NewTask、MenuBar、Settings
  Services/                 和系统打交道的服务（防睡眠等）
  Resources/                Assets.xcassets
Packages/MuleeCore/         不依赖 UI 的核心逻辑：数据模型、链接解析、示例数据
Design/                     品牌、图标规范、原型
```

## 设计对齐

- 设计以 Claude Design 原型为准：`Design/Prototype/` 下是原型源码（.dc.html），已实现界面的截图在 `docs/screenshots/`。颜色、间距、文案、信息层级要和原型一致；原型里的占位方块，换成 `Design/ICONS.md` 规定的 SF Symbols。
- 示例数据、截图、测试里**不使用真实的影视、游戏、书籍等版权作品名**，用虚构名称或开源内容（例如 Big Buck Bunny、Sintel、Ubuntu）。
- 图标只能通过 `MuleeSymbol` 枚举使用，不准在视图里写符号名字符串。
- 颜色只能用资源目录里的 `AccentColor`、`WaitColor`、`SuccessColor` 和系统语义色（`.primary`、`.secondary`、`.tertiary` 等）。不准自己写十六进制颜色。文件类型图标是例外：按 `Design/ICONS.md` 的 OKLCH 公式生成动态亮暗颜色，不写十六进制常量。
- 字号用系统文字样式（`.body`、`.callout`、`.subheadline`、`.caption` 等），不写死字号；`.caption2` 尽量不用。
- 文件图标统一用 `FileTypeIcon` 的「虚实」圆角方块，不使用访达系统文件图标。列表用 32pt，详情头部用 64pt；图形、PDF 文字及格式角标按画布比例缩放，是固定字号禁令的例外。

## SwiftUI 规则（摘自 swiftui-pro 规范）

- 用 `foregroundStyle()`，不用 `foregroundColor()`；用 `clipShape(.rect(cornerRadius:))`，不用 `cornerRadius()`。
- `onChange` 只用双参数或无参数的版本。
- 共享状态用 `@Observable` 类，持有方用 `@State`，传递用 `@Bindable` 或 `@Environment`。不用 `ObservableObject`、`@Published`、`@StateObject`、`@EnvironmentObject`。
- `@State` 一律 `private`。
- 不要用返回 `some View` 的计算属性或方法拆分 body，**拆成独立的 View 结构体，每个类型放一个文件**。
- 按钮的 action 抽成方法，不在 body 里写业务逻辑。
- 只有图标的按钮也要有文字：`Button("暂停", systemImage: MuleeSymbol.pause.name, action: pause)`，需要时加 `.labelStyle(.iconOnly)`。
- 不用 `onTapGesture` 代替按钮。
- 能用 `Label` 就不要手写 `HStack { Image; Text }`。
- 空状态用 `ContentUnavailableView`。
- 用 `Form`、`LabeledContent` 做设置页，滑块等控件包在 `LabeledContent` 里。
- 不用 `AnyView`；不用 `GeometryReader`，除非没有替代方案。
- 用 `#Preview`，不用 `PreviewProvider`。
- 数字、日期、文件大小用 FormatStyle，不用 `String(format:)`。**文件大小和速度一律用 `.byteCount(style: .file)`（十进制，和访达一致）**，不要用 `.binary` / `.memory`，否则同一个文件在 Mulee 和访达里显示的大小对不上。
- 不用 GCD（`DispatchQueue`），用 async/await；`Task.sleep(for:)`，不用纳秒版本。
- 不强制解包；错误不能静默吞掉。
- 每个类型一个文件。

## 并发

- 引擎相关的长期运行逻辑放在 actor 里，UI 状态放在 `@MainActor` 的 `@Observable` 类里。
- 跨隔离边界传递的模型类型必须是 `Sendable` 值类型。

## 文案

- 界面文案用简体中文，写成 `Text("全部任务")` 这样的字面量，后续统一抽取到 String Catalog 做多语言。
- 语气：冷门资源下不动不叫失败。规范见 `Design/BRAND.md`。

## 版本号

格式 `x.y.z`，由主控（Claude）统一管理，写在 `project.yml` 的 `MARKETING_VERSION`：

- `z`：0–99，每次可交付的改动加 1；到 99 之后再加，进位为 `y + 1`、`z` 归 0。
- `y`：0–9，到 9 之后再进位，进位为 `x + 1`、`y` 归 0。
- 例：`0.1.99` → `0.2.0`；`0.9.99` → `1.0.0`。
- 每次改版本号都打 git 标签 `v<x.y.z>`。`CURRENT_PROJECT_VERSION`（构建号）每次发版加 1。

## 提交

- 每个提交只做一件事，提交信息用英文祈使句（`feat(main-window): ...`）。
