import SwiftUI

/// 全 App 统一的设计常量。颜色来自资源目录，数值与 Claude Design 原型一致。
enum Theme {
    /// 「需要耐心」：电驴等待来源、Low ID、代理警告。
    static let wait = Color(.wait)
    /// 完成、正常、做种、解压。
    static let success = Color(.success)

    /// 主窗口最小尺寸（原型画布为 1240×780）。
    static let mainWindowMinWidth = 980.0
    static let mainWindowMinHeight = 600.0
    static let sidebarWidth = 220.0
    static let inspectorWidth = 300.0

    /// 列表行内进度条宽度。
    static let rowProgressWidth = 150.0
    /// 进度条高度。
    static let progressBarHeight = 4.0
    /// 卡片圆角。
    static let cardCornerRadius = 10.0
    /// 列表行圆角。
    static let rowCornerRadius = 8.0
}
