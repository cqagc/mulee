import AppKit
import SwiftUI

/// 主窗口的 sheet、链接拖放与提示由 SwiftUI 承载；三栏和工具栏由 AppKit 管理。
struct MainWindowView: View {
    @Environment(AppModel.self) private var model
    @State private var state = MainWindowState()

    var body: some View {
        @Bindable var model = model

        NativeMainSplitView(state: state)
            .focusedSceneValue(\.mainWindowState, state)
            .sheet(isPresented: $model.isShowingNewTask) {
                NewTaskSheet()
            }
            .onDrop(of: OpenURLDropHandler.types, isTargeted: nil) { providers in
                OpenURLDropHandler.accept(providers, model: model)
            }
            .alert("无法打开链接", isPresented: Binding(
                get: { model.openURLIssue != nil },
                set: { if !$0 { model.openURLIssue = nil } }
            )) {
                Button("好", role: .cancel) { model.openURLIssue = nil }
            } message: {
                Text(model.openURLIssue ?? "")
            }
            .onChange(of: state.selection) { state.clearHiddenSelection(in: model) }
            .onChange(of: state.search) { state.clearHiddenSelection(in: model) }
            .onChange(of: model.tasks) { state.clearHiddenSelection(in: model) }
    }
}

#if DEBUG
#Preview {
    MainWindowView()
        .environment(AppModel())
        .environment(SettingsModel())
}

#Preview("暗色") {
    MainWindowView()
        .environment(AppModel())
        .environment(SettingsModel())
        .preferredColorScheme(.dark)
}
#endif
