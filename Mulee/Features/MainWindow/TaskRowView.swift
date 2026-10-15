import SwiftUI

struct TaskRowView: View {
    let presentation: TaskPresentation

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
            .frame(width: Theme.rowProgressWidth)
            TaskStatusView(presentation: presentation)
                .frame(width: 110, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}
