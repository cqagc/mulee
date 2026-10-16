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
            VStack(spacing: 0) {
                DiskReserveBanner()
                TaskListView(tasks: state.visibleTasks(in: model), isSearching: !state.search.isEmpty)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .inspector:
            TaskInspectorView(task: model.selectedTask)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        }
    }
}
