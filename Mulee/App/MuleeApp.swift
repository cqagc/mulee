import MuleeCore
import SwiftUI

struct MuleeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel
    @State private var settings: SettingsModel

    init() {
        let session = SingleInstanceSession.current
        precondition(session.isPrimary)
        let settings = SettingsModel()
        _settings = State(initialValue: settings)
        let usesSampleData: Bool
        #if DEBUG
        usesSampleData = DebugLaunchOptions.usesSampleData
        #else
        usesSampleData = false
        #endif
        let model = AppModel(
            tasks: usesSampleData ? MockData.tasks : [],
            networkStatus: usesSampleData ? MockData.healthyNetwork : NetworkStatus(
                ed2kID: .disconnected, kad: .disconnected, bittorrentPortReachable: nil,
                p2pRoutedThroughProxy: false, p2pExitIP: nil, portMappingSucceeded: nil
            ),
            unzipRules: usesSampleData ? MockData.unzipRules : [],
            preventsSleepWhileDownloading: settings.preventSleep
        )
        if usesSampleData {
            // 示例数据模式不启动引擎；截图和预览里按「都已就绪」展示。
            for kind in TaskKind.allCases { model.engineStates[kind] = .running }
        }
        _model = State(initialValue: model)
        appDelegate.configureSingleInstance(session)
        appDelegate.configure(model: model, settings: settings, usesSampleData: usesSampleData)
    }

    var body: some Scene {
        WindowGroup("Mulee", id: "main") {
            MainWindowView()
                .frame(minWidth: Theme.mainWindowMinWidth, minHeight: Theme.mainWindowMinHeight)
                .debugLaunchOptions()
                .modifier(OnboardingLaunchModifier())
                .background(MainWindowRegistration(delegate: appDelegate))
                .modifier(SettingsSyncModifier())
                .environment(model)
                .environment(settings)
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .defaultSize(width: 1240, height: 780)
        .keyboardShortcut("n", modifiers: [.command, .shift])
        .commands {
            AppUpdateCommands(updates: appDelegate.updates)
            TaskHistoryCommands(model: model)
            AboutCommands()
            MainWindowCommands(model: model)
        }

        MenuBarExtra {
            MenuBarPanelView()
                .modifier(MainWindowPresenter())
                .modifier(SettingsSyncModifier())
                .environment(model)
                .environment(settings)
        } label: {
            MenuBarLabel()
                .modifier(MainWindowPresenter())
                .modifier(SettingsSyncModifier())
                .environment(model)
                .environment(settings)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .modifier(SettingsSyncModifier())
                .environment(model)
                .environment(settings)
                #if DEBUG
                .preferredColorScheme(DebugLaunchOptions.colorScheme)
                #endif
        }

        Window("关于 Mulee", id: "about") {
            AboutView()
                #if DEBUG
                .preferredColorScheme(DebugLaunchOptions.colorScheme)
                #endif
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .windowResizability(.contentSize)

        Window("默认下载工具", id: "onboarding") {
            OnboardingView()
                #if DEBUG
                .preferredColorScheme(DebugLaunchOptions.colorScheme)
                #endif
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .windowResizability(.contentSize)

        #if DEBUG
        Window("文件类型图标总览", id: "file-icon-gallery") {
            FileIconGalleryView()
        }
        .defaultSize(width: 1120, height: 1380)
        .windowResizability(.contentSize)

        // 仅用于截图核对：把菜单栏面板放进普通窗口。
        Window("菜单栏面板预览", id: "menu-bar-panel-preview") {
            MenuBarPanelView()
                .modifier(SettingsSyncModifier())
                .environment(model)
                .environment(settings)
                .preferredColorScheme(DebugLaunchOptions.colorScheme)
        }
        .windowResizability(.contentSize)
        #endif
    }
}
