import AppKit
import MuleeCore

/// 沿用任务删除入口，由用户选择是否同时删除已下载的数据。
enum BitTorrentRemoval {
    static func confirm(task: DownloadTask, model: AppModel) {
        let alert = NSAlert()
        alert.messageText = "删除「\(task.name)」？"
        alert.informativeText = "可以只移除任务，或同时删除已下载的文件。"
        alert.addButton(withTitle: "只删除任务")
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "同时删除文件")
        let result = alert.runModal()
        guard result != .alertSecondButtonReturn else { return }
        let deleteFiles = result == .alertThirdButtonReturn
        Task { await model.coordinator?.remove(task.id, deleteFiles: deleteFiles) }
    }
}
