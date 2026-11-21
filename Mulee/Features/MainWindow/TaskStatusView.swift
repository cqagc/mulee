import SwiftUI

struct TaskStatusView: View {
    let presentation: TaskPresentation
    /// 行被选中（蓝色高亮）时为 .increased，此时语义色和背景对比不足，改用系统前景色。
    @Environment(\.backgroundProminence) private var backgroundProminence

    private var color: Color {
        if backgroundProminence == .increased {
            return .primary
        }
        return switch presentation.task.status {
        case .waitingForSources, .failed: Theme.wait
        case .completed: Theme.success
        default: .primary
        }
    }

    var body: some View {
        if presentation.task.needsFileRelink == true {
            Label("文件位置已更改", systemImage: MuleeSymbol.statusFailed.name)
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(backgroundProminence == .increased ? Color.primary : Theme.wait)
                .help("已暂停。请选择“重新关联”或确认重新下载。")
        } else if presentation.task.fileMissing == true {
            Label("找不到文件", systemImage: MuleeSymbol.statusFailed.name)
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(backgroundProminence == .increased ? Color.primary : Theme.wait)
                .help("文件已不在，任务记录已保留。请检查文件是否已删除或所在磁盘是否已连接。")
        } else {
            VStack(alignment: .trailing, spacing: 3) {
                if presentation.showsBidirectionalRates {
                    TransferSpeedView(downloadRate: presentation.task.downloadRate, uploadRate: presentation.task.uploadRate)
                } else {
                    Label(presentation.statusTitle, systemImage: presentation.statusSymbol.name)
                        .labelStyle(.titleOnly)
                        .foregroundStyle(color)
                        .fontWeight(presentation.isStatusEmphasized ? .semibold : .regular)
                }
                if presentation.showsBidirectionalRates && (presentation.isYieldingSlot || presentation.task.status == .waitingForSources) {
                    Text(presentation.statusTitle)
                        .foregroundStyle(.secondary)
                } else if !presentation.statusSubtitle.isEmpty {
                    Text(presentation.statusSubtitle)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .monospacedDigit()
            .lineLimit(presentation.isYieldingSlot ? 2 : presentation.schedulePauseTitle == nil ? 1 : 3)
            .help(presentation.showsBidirectionalRates ? "\(String(localized: "下载速度 \(TaskPresentation.rate(presentation.task.downloadRate))"))  \(String(localized: "上传速度 \(TaskPresentation.rate(presentation.task.uploadRate))"))" : presentation.statusTitle)
        }
    }
}
