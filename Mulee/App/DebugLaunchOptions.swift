#if DEBUG
import SwiftUI

/// 仅 Debug 构建：用启动参数把 App 直接带到某个画面，方便截图和设计稿逐一比对。
///
///     open Mulee.app --args -MuleeAppearance dark -MuleeShowNewTask YES -MuleeOpenSettings YES -MuleeSettingsTab network
enum DebugLaunchOptions {
    private static let defaults = UserDefaults.standard

    /// 截图核对时使用示例数据，并且不启动下载引擎。
    static var usesSampleData: Bool { defaults.bool(forKey: "MuleeSampleData") || stressTaskCount > 0 }

    /// 列表压测沿用示例模式，确保不启动引擎、不读取或写入任务历史。
    static var stressTaskCount: Int { max(0, defaults.integer(forKey: "MuleeStressTasks")) }

    /// 测量滚动和每秒刷新同时发生时的开销。
    static var stressScrolls: Bool { defaults.bool(forKey: "MuleeStressScroll") }

    /// 启动后自动添加的链接文本（端到端验证用），引擎就绪后提交。
    static var linksToAdd: String? { defaults.string(forKey: "MuleeAddLinks") }

    /// 强制亮色或暗色；nil 表示跟随系统。
    static var colorScheme: ColorScheme? {
        switch defaults.string(forKey: "MuleeAppearance") {
        case "dark": .dark
        case "light": .light
        default: nil
        }
    }

    /// 启动后自动弹出「新建下载」，并预填原型里的 4 种链接。
    static var showsNewTask: Bool { defaults.bool(forKey: "MuleeShowNewTask") }

    /// 启动后自动打开设置窗口。
    static var opensSettings: Bool { defaults.bool(forKey: "MuleeOpenSettings") }

    /// 启动时设置窗口停在哪个标签页（SettingsTab 的 rawValue）。
    static var settingsTab: String? { defaults.string(forKey: "MuleeSettingsTab") }

    /// 把菜单栏面板放进普通窗口里显示（菜单栏弹窗无法直接截图）。
    static var showsMenuBarPanelWindow: Bool { defaults.bool(forKey: "MuleeShowMenuBarPanel") }

    /// 启动时打开亮暗对照的文件类型图标总览。
    static var showsIconGallery: Bool { defaults.bool(forKey: "MuleeShowIconGallery") }

    /// 打开关于窗口和首次引导预览；引导预览禁止更改系统默认程序。
    static var showsAbout: Bool { defaults.bool(forKey: "MuleeShowAbout") }
    static var showsOnboarding: Bool { defaults.bool(forKey: "MuleeShowOnboarding") }

    /// 用「P2P 走了代理」的网络状态启动，查看警告样式。
    static var usesProxiedNetwork: Bool { defaults.bool(forKey: "MuleeProxiedNetwork") }

    static let samplePasteText = """
        magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=Big+Buck+Bunny
        ed2k://|file|雾港奇谭 繁中版.rar|612000000|9F3A0C5E7D21B84A6C0E93F15B71DC21|/
        thunder://QUFodHRwczovL2V4YW1wbGUuY29tL3NpbnRlbC1vc3QuemlwWlo=
        https://www.bilibili.com/video/BV1xx411c7XX
        """
}
#endif
