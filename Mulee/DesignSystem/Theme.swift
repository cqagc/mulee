import SwiftUI

/// 全 App 统一的设计常量。颜色来自资源目录，数值与 Claude Design 原型一致。
enum Theme {
    /// 「需要耐心」：电驴等待来源、Low ID、代理警告。
    static let wait = Color(.wait)
    /// 完成、正常、做种、解压。
    static let success = Color(.success)

    /// 主窗口最小尺寸（原型画布为 1240×780）。
    static let mainWindowMinWidth = 1182.0
    static let mainWindowMinHeight = 600.0
    static let sidebarWidth = 220.0
    static let inspectorWidth = 300.0

    /// 列表行内进度列宽度：列表变宽时进度条跟着变长，超出上限的空间留给文件名。
    static let rowProgressMinWidth = 150.0
    static let rowProgressMaxWidth = 360.0
    static let rowProgressFraction = 0.28
    /// 进度条高度。
    static let progressBarHeight = 4.0
    /// 卡片圆角。
    static let cardCornerRadius = 10.0
    /// 列表行圆角。
    static let rowCornerRadius = 8.0
}
