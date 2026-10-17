import AppKit
import MuleeCore
import SwiftUI

struct TaskContextMenu: View {
    @Environment(AppModel.self) private var model
    let task: DownloadTask
    @State private var magnetURI: String?
    @State private var playbackFiles: [TorrentFileEntry] = []

    private var presentation: TaskPresentation { TaskPresentation(task: task) }

    var body: some View {
        if task.deletedAt != nil {
            Button("恢复任务", systemImage: MuleeSymbol.retry.name) { model.restoreRecord(task.id) }
            Button("彻底删除记录", systemImage: MuleeSymbol.delete.name, role: .destructive) { model.removeRecord(task.id) }
        } else {
            activeMenu
                .task(id: task.id) {
                    magnetURI = nil
                    if task.kind == .bittorrent, let id = task.engineTaskID {
                        let uri = try? await model.bitTorrent?.engine.magnetURI(id)
                        guard !Task.isCancelled else { return }
                        magnetURI = uri
                        playbackFiles = (try? await model.bitTorrent?.engine.files(id)) ?? []
                    }
                }
        }
    }

    @ViewBuilder
    private var activeMenu: some View {
        Button(presentation.pauseTitle, systemImage: presentation.pauseSymbol.name, action: togglePause)
            .disabled(!presentation.canPauseOrResume)
        if StreamingPlayback.canPlay(task, files: playbackFiles) {
            Button("播放", systemImage: "play.fill") {
                StreamingPlayback.shared.play(task: task, engine: model.bitTorrent?.engine, coordinator: model.coordinator)
            }
        }
        Button("复制链接", systemImage: MuleeSymbol.copy.name, action: copyLink)
        if let magnetURI {
            Button("复制磁力链接", systemImage: MuleeSymbol.copy.name) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(magnetURI, forType: .string)
            }
        }
        Button("在访达中显示", systemImage: MuleeSymbol.revealInFinder.name, action: reveal)
        Button((task.tags ?? []).isEmpty ? String(localized: "添加标签…") : String(localized: "编辑标签…"), systemImage: MuleeSymbol.tags.name) { TaskActions.editTags(task, model: model) }
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
        TaskActions.copyLink(task)
    }

    private func reveal() {
        TaskActions.reveal(task)
    }

    private func remove() {
        model.remove(task.id)
    }
}
