import SwiftUI

/// App 菜单中的历史清理入口。
struct TaskHistoryCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Button("清除已完成的任务", action: clearCompletedTasks)
                .keyboardShortcut(.delete, modifiers: [.option, .command])
                .disabled(!model.hasCompletedTasks)
        }
    }

    private func clearCompletedTasks() {
        model.clearCompletedTasks()
    }
}
