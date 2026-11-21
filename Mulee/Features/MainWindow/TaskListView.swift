import AppKit
import MuleeCore
import SwiftUI

struct TaskListView: View {
    @Environment(AppModel.self) private var model
    @Environment(SettingsModel.self) private var settings
    @State private var cleanupIDs: Set<UUID> = []
    let tasks: [DownloadTask]
    let isSearching: Bool

    var body: some View {
        @Bindable var model = model
        let sortedTasks = TaskSort(settings.taskSort).sorted(tasks)

        let missingIDs = model.missingFileRecordCandidates(in: Set(tasks.map(\.id)))

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
                    .accessibilityActions {
                        TaskContextMenu(task: task)
                    }
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let task = tasks.first(where: { ids.contains($0.id) }) {
                TaskContextMenu(task: task)
            }
        } primaryAction: { ids in
            if let task = tasks.first(where: { ids.contains($0.id) }) {
                TaskActions.openDownload(task, defaultDirectory: URL(filePath: settings.saveDirectory))
            }
        }
        .listStyle(.inset)
        .scrollEdgeEffectStyle(.hard, for: .top)
        .safeAreaBar(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                DiskReserveBanner()
                HStack {
                    Spacer()
                    if !cleanupIDs.isEmpty {
                        Button("清理缺失记录（\(cleanupIDs.count)）", systemImage: MuleeSymbol.delete.name) {
                            let ids = cleanupIDs
                            TaskRemoval.confirmMissing(count: ids.count) {
                                await model.trashMissingFileRecords(ids)
                                cleanupIDs = model.confirmedMissingFileRecords(in: model.missingFileRecordCandidates(in: cleanupIDs))
                            }
                        }
                        .help("将当前列表中找不到文件的记录移到“最近删除”，30 天内可恢复。")
                    }
                    Menu("排序") {
                        Picker("排序依据", selection: Binding(
                            get: { TaskSort(settings.taskSort).key },
                            set: { settings.taskSort = TaskSort(key: $0, ascending: TaskSort(settings.taskSort).ascending).value }
                        )) {
                            ForEach(TaskSort.Key.allCases, id: \.self) { key in
                                Text(key.title).tag(key)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                        Divider()
                        Picker("排序方向", selection: Binding(
                            get: { TaskSort(settings.taskSort).ascending },
                            set: { settings.taskSort = TaskSort(key: TaskSort(settings.taskSort).key, ascending: $0).value }
                        )) {
                            Text("升序").tag(true)
                            Text("降序").tag(false)
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                    .fixedSize()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
        }
        .overlay {
            if tasks.isEmpty {
                ContentUnavailableView(isSearching ? String(localized: "未找到任务") : String(localized: "暂无任务"),
                                       systemImage: isSearching ? MuleeSymbol.search.name : MuleeSymbol.all.name,
                                       description: Text(isSearching ? String(localized: "试试其他任务名称。") : String(localized: "新建下载后，任务会显示在这里。")))
            }
        }
        .onAppear { model.refreshTrackedFiles() }
        .onChange(of: missingIDs, initial: true) { _, ids in
            cleanupIDs = model.confirmedMissingFileRecords(in: ids)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshTrackedFiles()
            cleanupIDs = model.confirmedMissingFileRecords(in: missingIDs)
        }
    }
}
