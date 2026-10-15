import AppKit
import MuleeCore

/// 沿用任务删除入口，由用户选择是否同时删除已下载的数据。
enum BitTorrentRemoval {
    static func confirm(task: DownloadTask, model: AppModel) {
        let alert = NSAlert()
        alert.messageText = String(localized: "删除「\(task.name)」？")
        alert.informativeText = task.kind == .ed2k && task.status != .completed
            ? String(localized: "未完成的电驴分块会随任务移除；已完成的文件可以保留。")
            : String(localized: "可以只移除任务，或同时删除已下载的文件。")
        alert.addButton(withTitle: String(localized: "只删除任务"))
        alert.addButton(withTitle: String(localized: "取消"))
        alert.addButton(withTitle: String(localized: "同时删除文件"))
        let result = alert.runModal()
        guard result != .alertSecondButtonReturn else { return }
        let deleteFiles = result == .alertThirdButtonReturn
        Task { await model.coordinator?.remove(task.id, deleteFiles: deleteFiles) }
    }
}
