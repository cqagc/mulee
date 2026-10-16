import MuleeCore
import SwiftUI

struct TaskInspectorActions: View {
    @Environment(AppModel.self) private var model
    let task: DownloadTask

    private var presentation: TaskPresentation { TaskPresentation(task: task) }

    var body: some View {
        HStack(spacing: 6) {
            Button(presentation.pauseTitle, systemImage: presentation.pauseSymbol.name, action: togglePause)
                .disabled(task.deletedAt != nil || !presentation.canPauseOrResume)
            Button("复制链接", systemImage: MuleeSymbol.copy.name, action: copyLink)
            Button("在访达中显示", systemImage: MuleeSymbol.revealInFinder.name, action: reveal)
        }
        .labelStyle(.titleOnly)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
    }

    private func togglePause() {
        if task.status == .paused {
            model.resume(task.id)
        } else {
            model.pause(task.id)
        }
    }

    private func copyLink() {
        TaskActions.copyLink(task)
    }

    private func reveal() {
        TaskActions.reveal(task)
    }
}
