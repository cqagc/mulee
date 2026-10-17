import AppKit
import MuleeCore
import SwiftUI

struct TaskContextMenu: View {
    @Environment(AppModel.self) private var model
    let task: DownloadTask

    private var presentation: TaskPresentation { TaskPresentation(task: task) }

    var body: some View {
        if task.deletedAt != nil {
            Button("恢复任务", systemImage: MuleeSymbol.retry.name) { model.restoreRecord(task.id) }
            Button("彻底删除记录", systemImage: MuleeSymbol.delete.name, role: .destructive) { model.removeRecord(task.id) }
        } else {
            activeMenu
        }
    }

    @ViewBuilder
    private var activeMenu: some View {
        Button(presentation.pauseTitle, systemImage: presentation.pauseSymbol.name, action: togglePause)
            .disabled(!presentation.canPauseOrResume)
        if StreamingPlayback.canPlay(task) {
            Button("播放", systemImage: MuleeSymbol.resume.name) {
                StreamingPlayback.shared.play(task: task, engine: model.bitTorrent?.engine, coordinator: model.coordinator)
            }
        }
        Button("复制链接", systemImage: MuleeSymbol.copy.name, action: copyLink)
        if TaskActions.canCopyMagnet(task) {
            Button("复制磁力链接", systemImage: MuleeSymbol.copy.name) {
                TaskActions.copyMagnet(task, model: model)
            }
        }
        Button("在访达中显示", systemImage: MuleeSymbol.revealInFinder.name, action: reveal)
        Button((task.tags ?? []).isEmpty ? String(localized: "添加标签…") : String(localized: "编辑标签…"), systemImage: MuleeSymbol.tags.name) { TaskActions.editTags(task, model: model) }
        if presentation.showsQueueActions {
            Divider()
            Button("移到队列最前") { model.coordinator?.moveInQueue(task.id, toFront: true) }
            Button("移到队列最后") { model.coordinator?.moveInQueue(task.id, toFront: false) }
            Menu("优先级") {
                Picker("优先级", selection: Binding(
                    get: { task.priority },
                    set: { model.coordinator?.setPriority(task.id, priority: $0) }
                )) {
                    Text("高").tag(DownloadTask.Priority.high)
                    Text("中").tag(DownloadTask.Priority.normal)
                    Text("低").tag(DownloadTask.Priority.low)
                }
            }
        }
        if task.kind == .bittorrent {
            Divider()
            BitTorrentActionsView(task: task)
        }
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
        TaskActions.copyLink(task, model: model)
    }

    private func reveal() {
        TaskActions.reveal(task)
    }

    private func remove() {
        model.remove(task.id)
    }
}
