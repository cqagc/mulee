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
        VStack(alignment: .trailing, spacing: 3) {
            Label(presentation.statusTitle, systemImage: presentation.statusSymbol.name)
                .labelStyle(.titleOnly)
                .foregroundStyle(color)
                .fontWeight(presentation.isStatusEmphasized ? .semibold : .regular)
            if !presentation.statusSubtitle.isEmpty {
                Text(presentation.statusSubtitle)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .monospacedDigit()
        .lineLimit(presentation.isYieldingSlot ? 2 : presentation.schedulePauseTitle == nil ? 1 : 3)
        .help(presentation.statusTitle)
    }
}
