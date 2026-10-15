import AppKit
import SwiftUI

/// 粘贴链接的输入框，回车后打开「新建下载」并预填。
struct MenuBarPasteField: View {
    @Environment(AppModel.self) private var model
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
        model.showNewTask(prefill: trimmed)
        openWindow(id: "main")
        NSApplication.shared.activate()
        text = ""
    }
}

#Preview {
    MenuBarPasteField()
        .environment(AppModel())
        .padding()
        .frame(width: 340)
}
