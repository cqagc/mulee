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
            Button("制作种子…") { CreateTorrentPanel.show(model: model) }
                .disabled(model.bitTorrent == nil)
        }
        CommandMenu("下载") {
            Button(model.isSlowModeActive ? String(localized: "关闭慢速模式") : String(localized: "开启慢速模式")) {
                model.slowModeController?.toggle()
            }
            Menu("本次下完后") {
                ForEach(WhenAllDoneAction.allCases) { action in
                    Button {
                        model.whenAllDoneController?.select(action)
                    } label: {
                        if model.whenAllDoneAction == action {
                            Label(action.title, systemImage: MuleeSymbol.statusCompleted.name)
                        } else {
                            Text(action.title)
                        }
                    }
                }
            }
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
