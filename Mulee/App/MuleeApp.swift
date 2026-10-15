import SwiftUI

@main
struct MuleeApp: App {
    @State private var model: AppModel
    @State private var settings: SettingsModel

    init() {
        let settings = SettingsModel()
        _settings = State(initialValue: settings)
        _model = State(initialValue: AppModel(preventsSleepWhileDownloading: settings.preventSleep))
    }

    var body: some Scene {
        WindowGroup("Mulee", id: "main") {
            MainWindowView()
                .frame(minWidth: Theme.mainWindowMinWidth, minHeight: Theme.mainWindowMinHeight)
                .debugLaunchOptions()
                .modifier(SettingsSyncModifier())
                .environment(model)
                .environment(settings)
        }
        .defaultSize(width: 1240, height: 780)
        .keyboardShortcut("n", modifiers: [.command, .shift])

        MenuBarExtra {
            MenuBarPanelView()
                .modifier(SettingsSyncModifier())
                .environment(model)
                .environment(settings)
        } label: {
            MenuBarLabel()
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

        #if DEBUG
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
