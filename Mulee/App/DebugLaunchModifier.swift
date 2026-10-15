import MuleeCore
import SwiftUI

/// 在 Debug 构建里执行 DebugLaunchOptions 指定的启动动作；Release 构建里什么都不做。
struct DebugLaunchModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(SettingsModel.self) private var settings
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
    private static var didAddLaunchLinks = false

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
        if DebugLaunchOptions.showsAbout {
            openWindow(id: "about")
        }
        if DebugLaunchOptions.showsOnboarding {
            openWindow(id: "onboarding")
        }
        if DebugLaunchOptions.showsIconGallery {
            openWindow(id: "file-icon-gallery")
        }
        if let text = DebugLaunchOptions.linksToAdd, !Self.didAddLaunchLinks {
            Self.didAddLaunchLinks = true
            // 等待所需引擎就绪；慢启动不能把端到端任务误记为引擎未运行。
            let kinds = Set(LinkParser.parse(text).map(\.kind))
            for _ in 0..<120 {
                if kinds.allSatisfy({ model.engineStates[$0] == .running }) { break }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
            model.addTasks(from: LinkParser.parse(text), autoExtract: settings.autoExtract)
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
