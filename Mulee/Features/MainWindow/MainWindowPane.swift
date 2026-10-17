import SwiftUI

/// 各栏独立观察同一份模型，避免列表刷新时重新创建 hosting controller。
struct MainWindowPane: View {
    enum Kind {
        case sidebar, tasks, inspector
    }

    let kind: Kind
    @Bindable var state: MainWindowState
    @Environment(AppModel.self) private var model

    var body: some View {
        switch kind {
        case .sidebar:
            MainSidebarView(selection: $state.selection)
        case .tasks:
            TaskListView(tasks: state.visibleTasks(in: model), isSearching: !state.search.isEmpty)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .inspector:
            TaskInspectorView(task: model.selectedTask)
                .environment(\.bitTorrentInspectorCollapsed, state.isInspectorCollapsed)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
                // 与侧边栏同理：inspector 分栏项让 SwiftUI 按旧式毛玻璃绘制，传统滚动条滑块会变成深色实心块。
                .environment(\.backgroundMaterial, nil)
        }
    }
}
