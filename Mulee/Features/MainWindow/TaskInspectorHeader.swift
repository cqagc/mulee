import SwiftUI

struct TaskInspectorHeader: View {
    let presentation: TaskPresentation

    var body: some View {
        HStack(spacing: 12) {
            FileTypeIcon(
                category: FileCategory(task: presentation.task),
                state: FileIconState(task: presentation.task),
                extension: presentation.task.fileExtension,
                size: 64
            )
            VStack(alignment: .leading, spacing: 6) {
                Text(presentation.task.name)
                    .font(.headline)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    TaskTypeBadge(title: presentation.typeLabel)
                    Text(presentation.size)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
