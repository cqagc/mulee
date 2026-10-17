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
            let presentation = TaskPresentation(
                task: displayTask, seedingAction: settings.seedingAction, schedule: .init(settings: settings),
                isYieldingSlot: model.stalledYieldTaskIDs.contains(task.id)
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TaskInspectorHeader(presentation: presentation)
                    if presentation.showsTaskLimits { TaskLimitsCard(task: task) }
                    playbackControls(task)
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
    @ViewBuilder
    private func playbackControls(_ task: DownloadTask) -> some View {
        let playback = StreamingPlayback.shared
        if task.deletedAt == nil {
            if StreamingPlayback.showsBuffering(task: task, progress: playback.buffering[task.id]),
               let progress = playback.buffering[task.id] {
                VStack(alignment: .leading, spacing: 8) {
                    Text("正在缓冲开头部分，完成后自动打开播放器")
                        .font(.caption)
                    ProgressView(value: progress)
                        .accessibilityLabel("播放缓冲进度")
                        .accessibilityValue(progress.formatted(.percent.precision(.fractionLength(0))))
                    Button("取消") { playback.cancel(task.id) }
                }
            } else if playback.playing.contains(task.id), ![.completed, .seeding].contains(task.status) {
                Button("取消边下边播") { playback.cancel(task.id) }
            } else if StreamingPlayback.canPlay(task, files: torrentModel.files) {
                Button("播放", systemImage: "play.fill") {
                    playback.play(task: task, engine: model.bitTorrent?.engine, coordinator: model.coordinator)
                }
            }
            if let issue = playback.issues[task.id] {
                Text(issue).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

}
