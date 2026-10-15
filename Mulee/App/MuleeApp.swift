import SwiftUI

@main
struct MuleeApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Mulee", id: "main") {
            MainWindowView()
                .frame(minWidth: Theme.mainWindowMinWidth, minHeight: Theme.mainWindowMinHeight)
                .debugLaunchOptions()
                .environment(model)
        }
        .defaultSize(width: 1240, height: 780)
        .keyboardShortcut("n", modifiers: [.command, .shift])

        MenuBarExtra {
            MenuBarPanelView()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
                #if DEBUG
                .preferredColorScheme(DebugLaunchOptions.colorScheme)
                #endif
        }

        #if DEBUG
        // 仅用于截图核对：把菜单栏面板放进普通窗口。
        Window("菜单栏面板预览", id: "menu-bar-panel-preview") {
            MenuBarPanelView()
                .environment(model)
                .preferredColorScheme(DebugLaunchOptions.colorScheme)
        }
        .windowResizability(.contentSize)
        #endif
    }
}
