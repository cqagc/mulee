import MuleeCore
import SwiftUI

struct TaskListView: View {
    @Environment(AppModel.self) private var model
    @Environment(SettingsModel.self) private var settings
    let tasks: [DownloadTask]
    let isSearching: Bool

    var body: some View {
        @Bindable var model = model

        List(selection: $model.selectedTaskID) {
            ForEach(tasks) { task in
                TaskRowView(presentation: TaskPresentation(task: task, seedingAction: settings.seedingAction))
                    .tag(task.id)
                    .listRowInsets(EdgeInsets(top: 9, leading: 10, bottom: 9, trailing: 10))
                    .listRowSeparator(.hidden)
                    .contextMenu {
                        TaskContextMenu(task: task)
                    }
                    .accessibilityActions {
                        TaskContextMenu(task: task)
                    }
            }
        }
        .listStyle(.inset)
        .overlay {
            if tasks.isEmpty {
                ContentUnavailableView(isSearching ? "未找到任务" : "暂无任务",
                                       systemImage: isSearching ? MuleeSymbol.search.name : MuleeSymbol.all.name,
                                       description: Text(isSearching ? "试试其他任务名称。" : "新建下载后，任务会显示在这里。"))
            }
        }
    }
}
