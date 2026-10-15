import SwiftUI

struct TaskInspectorHeader: View {
    let presentation: TaskPresentation

    var body: some View {
        HStack(spacing: 12) {
            TaskFileIcon(task: presentation.task, size: 52)
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
