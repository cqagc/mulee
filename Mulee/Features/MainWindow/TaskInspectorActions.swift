import MuleeCore
import SwiftUI

struct TaskInspectorActions: View {
    @Environment(AppModel.self) private var model
    let task: DownloadTask

    private var presentation: TaskPresentation { TaskPresentation(task: task) }

    var body: some View {
        HStack(spacing: 6) {
            Button(presentation.pauseTitle, systemImage: presentation.pauseSymbol.name, action: togglePause)
                .disabled(task.deletedAt != nil || task.needsFileRelink == true || !presentation.canPauseOrResume)
            Button("复制链接", systemImage: MuleeSymbol.copy.name, action: copyLink)
            Button("在访达中显示", systemImage: MuleeSymbol.revealInFinder.name, action: reveal)
            if task.deletedAt == nil {
                Button("删除", systemImage: MuleeSymbol.delete.name, role: .destructive) {
                    TaskRemoval.confirm(task, in: model)
                }
                .labelStyle(.iconOnly)
                .help("删除")
            }
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
        TaskActions.copyLink(task, model: model)
    }

    private func reveal() {
        TaskActions.reveal(task)
    }
}

/// 列表菜单与详情栏共享同一提交状态，避免从两个入口重复添加任务。
struct MissingFileRedownloadButton: View {
    @Environment(AppModel.self) private var model
    let task: DownloadTask

    var body: some View {
        Button("重新下载", systemImage: MuleeSymbol.retry.name) {
            Task { await model.redownloadMissingFile(task.id) }
        }
        .disabled(model.redownloadingIDs.contains(task.id))
    }
}
