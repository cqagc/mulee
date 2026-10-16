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
            .overlay {
                if state.isDropTargeted { NewTaskDropHint() }
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

struct NewTaskDropHint: View {
    var body: some View {
        ZStack {
            Color.accentColor.opacity(0.15)
            Text("松开以添加下载")
                .font(.title2.weight(.semibold))
                .padding(24)
                .background(.regularMaterial, in: .rect(cornerRadius: 12))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
        }
        .allowsHitTesting(false)
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
