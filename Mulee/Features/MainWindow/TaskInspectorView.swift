import MuleeCore
import SwiftUI

struct TaskInspectorView: View {
    @Environment(SettingsModel.self) private var settings
    let task: DownloadTask?

    var body: some View {
        if let task {
            let presentation = TaskPresentation(task: task, seedingAction: settings.seedingAction)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TaskInspectorHeader(presentation: presentation)
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
                    if task.kind == .bittorrent {
                        BitTorrentInspectorView(task: task)
                    }
                    PostDownloadCard(presentation: presentation)
                }
                .padding(18)
            }
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
