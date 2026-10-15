import AppKit
import MuleeCore
import SwiftUI

/// 粘贴链接的输入框，回车后交给协调器下载。
struct MenuBarPasteField: View {
    @Environment(AppModel.self) private var model
    @Environment(SettingsModel.self) private var settings
    @Environment(\.openWindow) private var openWindow
    @State private var text = ""

    var body: some View {
        TextField("粘贴链接，回车直接下载", text: $text)
            .textFieldStyle(.roundedBorder)
            .controlSize(.large)
            .font(.callout)
            .onSubmit(submit)
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let links = LinkParser.parse(trimmed)
        if links.isEmpty {
            model.showNewTask(prefill: trimmed)
            openWindow(id: "main")
            NSApplication.shared.activate()
        } else {
            model.addTasks(from: links, autoExtract: settings.autoExtract)
        }
        text = ""
    }
}

#Preview {
    MenuBarPasteField()
        .environment(AppModel(tasks: MockData.tasks))
        .environment(SettingsModel())
        .padding()
        .frame(width: 340)
}
