import MuleeCore
import SwiftUI

struct TaskInspectorView: View {
    @Environment(AppModel.self) private var model
    @Environment(SettingsModel.self) private var settings
    let task: DownloadTask?
    @State private var torrentModel = BitTorrentFilesModel()

    var body: some View {
        if let task {
            let displayTask = task.kind == .bittorrent ? torrentModel.displayTask(task) : task
            let presentation = TaskPresentation(task: displayTask, seedingAction: settings.seedingAction)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TaskInspectorHeader(presentation: presentation)
                    if task.deletedAt != nil {
                        Text("任务已在最近删除中，30 天后清除记录，下载文件不受影响。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("恢复任务") { model.restoreRecord(task.id) }
                            Button("彻底删除记录", role: .destructive) { model.removeRecord(task.id) }
                        }
                    }
                    if task.fileMissing == true {
                        Text("文件已不在，任务记录已保留。请检查文件是否已删除或所在磁盘是否已连接。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("分类", value: DownloadCategory.classify(
                        extension: task.fileExtension ?? URL(filePath: task.name).pathExtension
                    )?.folderName ?? String(localized: "其他"))
                    LabeledContent("标签") {
                        Button((task.tags ?? []).isEmpty ? String(localized: "添加标签…") : (task.tags ?? []).joined(separator: ", ")) {
                            TaskActions.editTags(task, model: model)
                        }
                        .disabled(task.deletedAt != nil)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        TaskProgressBar(progress: presentation.progress, style: presentation.progressStyle, height: 6)
                        Text(presentation.inspectorProgressText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    if let info = presentation.longTail {
                        Text("冷门老资源会慢慢来。没有来源不算失败，Mulee 会一直替你挂着，有人上线就自动开始。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        LongTailCard(presentation: presentation)
                        SourceHistoryChart(sightings: info.dailySourceSightings)
                    } else {
                        TaskInformationCard(presentation: presentation)
                    }
                    if task.kind == .bittorrent, task.deletedAt == nil {
                        BitTorrentInspectorView(task: task, model: torrentModel)
                    }
                    PostDownloadCard(presentation: presentation)
                        .disabled(task.deletedAt != nil)
                    if task.deletedAt == nil {
                        if task.kind == .http { HTTPTaskActionsView(task: task).id(task.id) }
                        TaskChecksumView(task: task).id(task.id)
                    }
                }
                .padding(18)
            }
            .task(id: task.id) { model.refreshTrackedFile(task.id) }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                TaskInspectorActions(task: task)
                    .padding(14)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
        } else {
            ContentUnavailableView("选择一个任务", systemImage: MuleeSymbol.inspector.name,
                                   description: Text("查看进度、来源和完成后的处理信息。"))
        }
    }
}
