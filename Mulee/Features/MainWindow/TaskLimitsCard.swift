import MuleeCore
import SwiftUI

struct TaskLimitsCard: View {
    @Environment(AppModel.self) private var model
    let task: DownloadTask
    @State private var unit: Int64 = 1_000_000

    var body: some View {
        InspectorCard("队列与限速") {
            Picker("优先级", selection: Binding(
                get: { task.priority },
                set: { model.coordinator?.setPriority(task.id, priority: $0) }
            )) {
                Text("高").tag(DownloadTask.Priority.high)
                Text("中").tag(DownloadTask.Priority.normal)
                Text("低").tag(DownloadTask.Priority.low)
            }
            if [.http, .bittorrent].contains(task.kind) {
                Picker("限速单位", selection: $unit) {
                    Text("KB/s").tag(Int64(1_000))
                    Text("MB/s").tag(Int64(1_000_000))
                }
                limitField("下载限速", upload: false)
                if task.kind == .bittorrent { limitField("上传限速", upload: true) }
                Text("0 表示不限速；全局限速仍然生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("优先级和队列位置只影响等待中的任务，不会暂停正在下载的任务。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func limitField(_ title: LocalizedStringKey, upload: Bool) -> some View {
        LabeledContent(title) {
            TextField(title, value: Binding(
                get: { Double((upload ? task.uploadLimit : task.downloadLimit) ?? 0) / Double(unit) },
                set: { value in
                    guard value.isFinite else { return }
                    let bytes = Int64(min(Double(Int32.max), max(0, value) * Double(unit)))
                    guard let current = model.tasks.first(where: { $0.id == task.id }) else { return }
                    model.coordinator?.setTaskLimits(
                        task.id, download: upload ? current.downloadLimit : bytes,
                        upload: upload ? bytes : current.uploadLimit
                    )
                }
            ), format: .number.grouping(.never))
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: 80)
        }
    }
}
