import MuleeCore
import SwiftUI

/// 在 Debug 构建里执行 DebugLaunchOptions 指定的启动动作；Release 构建里什么都不做。
struct DebugLaunchModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        #if DEBUG
        content
            .preferredColorScheme(DebugLaunchOptions.colorScheme)
            .task(applyLaunchOptions)
        #else
        content
        #endif
    }

    #if DEBUG
    private func applyLaunchOptions() async {
        if DebugLaunchOptions.usesProxiedNetwork {
            model.networkStatus = MockData.proxiedNetwork
        }
        if DebugLaunchOptions.showsNewTask {
            model.showNewTask(prefill: DebugLaunchOptions.samplePasteText)
        }
        if DebugLaunchOptions.opensSettings {
            openSettings()
        }
        if DebugLaunchOptions.showsMenuBarPanelWindow {
            openWindow(id: "menu-bar-panel-preview")
        }
    }
    #endif
}

extension View {
    /// 挂在主窗口根视图上，处理 Debug 启动参数。
    func debugLaunchOptions() -> some View {
        modifier(DebugLaunchModifier())
    }
}
