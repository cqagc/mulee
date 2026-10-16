import SwiftUI

struct TaskRowView: View, Equatable {
    let presentation: TaskPresentation

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.presentation.task == rhs.presentation.task,
              lhs.presentation.seedingAction == rhs.presentation.seedingAction,
              lhs.presentation.calendar == rhs.presentation.calendar else { return false }
        // 等待天数仍随时钟变化；其他行不因每次新建 presentation 的 now 而重绘。
        return lhs.presentation.task.status != .waitingForSources
            || lhs.presentation.statusSubtitle == rhs.presentation.statusSubtitle
    }

    var body: some View {
        HStack(spacing: 12) {
            FileTypeIcon(
                category: FileCategory(task: presentation.task),
                state: FileIconState(task: presentation.task),
                extension: presentation.task.fileExtension,
                size: 32
            )
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.task.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .help(presentation.task.name)
                HStack(spacing: 6) {
                    TaskTypeBadge(title: presentation.typeLabel)
                    Text(presentation.metadata)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(presentation.metadata)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) {
                TaskProgressBar(progress: presentation.progress, style: presentation.progressStyle)
                Text(presentation.progressText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .help(presentation.progressText)
            }
            // 按列表宽度取固定比例，两侧栏收起时进度条变长，又不和文件名抢空间。
            .containerRelativeFrame(.horizontal) { width, _ in
                min(max(width * Theme.rowProgressFraction, Theme.rowProgressMinWidth), Theme.rowProgressMaxWidth)
            }
            TaskStatusView(presentation: presentation)
                .frame(width: 110, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}
