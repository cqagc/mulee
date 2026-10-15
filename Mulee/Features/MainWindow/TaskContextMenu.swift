import MuleeCore
import SwiftUI

struct TaskContextMenu: View {
    @Environment(AppModel.self) private var model
    let task: DownloadTask

    private var presentation: TaskPresentation { TaskPresentation(task: task) }

    var body: some View {
        Button(presentation.pauseTitle, systemImage: presentation.pauseSymbol.name, action: togglePause)
            .disabled(!presentation.canPauseOrResume)
        Button("复制链接", systemImage: MuleeSymbol.copy.name, action: copyLink)
        Button("在访达中显示", systemImage: MuleeSymbol.revealInFinder.name, action: reveal)
        Divider()
        Button("删除", systemImage: MuleeSymbol.delete.name, role: .destructive, action: remove)
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

    private func remove() {
        model.remove(task.id)
    }
}
