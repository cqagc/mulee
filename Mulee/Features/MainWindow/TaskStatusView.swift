import SwiftUI

struct TaskStatusView: View {
    let presentation: TaskPresentation

    private var color: Color {
        switch presentation.task.status {
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
        .lineLimit(1)
    }
}
