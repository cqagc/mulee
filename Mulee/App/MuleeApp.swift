import SwiftUI

@main
struct MuleeApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Mulee", id: "main") {
            MainWindowView()
                .environment(model)
                .frame(minWidth: Theme.mainWindowMinWidth, minHeight: Theme.mainWindowMinHeight)
        }
        .defaultSize(width: 1240, height: 780)

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
        }
    }
}
