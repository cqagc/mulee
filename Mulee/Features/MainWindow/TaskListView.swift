import MuleeCore
import SwiftUI

struct TaskListView: View {
    @Environment(AppModel.self) private var model
    @Environment(SettingsModel.self) private var settings
    let tasks: [DownloadTask]
    let isSearching: Bool

    var body: some View {
        @Bindable var model = model
        let sortedTasks = TaskSort(settings.taskSort).sorted(tasks)

        List(selection: $model.selectedTaskID) {
            ForEach(sortedTasks) { task in
                TaskRowView(presentation: TaskPresentation(
                    task: task, seedingAction: settings.seedingAction, schedule: .init(settings: settings),
                    isYieldingSlot: model.stalledYieldTaskIDs.contains(task.id)
                ))
                    .equatable()
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
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Spacer()
                Menu("排序") {
                    Picker("排序依据", selection: Binding(
                        get: { TaskSort(settings.taskSort).key },
                        set: { settings.taskSort = TaskSort(key: $0, ascending: TaskSort(settings.taskSort).ascending).value }
                    )) {
                        ForEach(TaskSort.Key.allCases, id: \.self) { key in
                            Text(key.title).tag(key)
                        }
                    }
                    Picker("排序方向", selection: Binding(
                        get: { TaskSort(settings.taskSort).ascending },
                        set: { settings.taskSort = TaskSort(key: TaskSort(settings.taskSort).key, ascending: $0).value }
                    )) {
                        Text("升序").tag(true)
                        Text("降序").tag(false)
                    }
                }
                .fixedSize()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
        .overlay {
            if tasks.isEmpty {
                ContentUnavailableView(isSearching ? String(localized: "未找到任务") : String(localized: "暂无任务"),
                                       systemImage: isSearching ? MuleeSymbol.search.name : MuleeSymbol.all.name,
                                       description: Text(isSearching ? String(localized: "试试其他任务名称。") : String(localized: "新建下载后，任务会显示在这里。")))
            }
        }
    }
}
