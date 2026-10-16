import SwiftUI

struct MainWindowStateKey: FocusedValueKey {
    typealias Value = MainWindowState
}

extension FocusedValues {
    var mainWindowState: MainWindowState? {
        get { self[MainWindowStateKey.self] }
        set { self[MainWindowStateKey.self] = newValue }
    }
}

struct MainWindowCommands: Commands {
    let model: AppModel
    @FocusedValue(\.mainWindowState) private var state

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("新建下载") { model.showNewTask() }
                .keyboardShortcut("n")
        }
        CommandGroup(after: .toolbar) {
            Button(state?.sidebarToggleTitle ?? String(localized: "显示边栏")) {
                state?.isSidebarCollapsed.toggle()
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .disabled(state == nil)
            Button(state?.inspectorToggleTitle ?? String(localized: "显示详情栏")) {
                state?.isInspectorCollapsed.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(state == nil)
        }
    }
}
