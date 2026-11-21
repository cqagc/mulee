import AppKit
import MuleeCore

@MainActor
enum TaskRemoval {
    static func confirm(_ task: DownloadTask, in model: AppModel) {
        let permanent = task.deletedAt != nil
        let message: String
        if permanent {
            message = String(localized: "彻底删除后，无法从“最近删除”恢复这条记录。")
        } else if task.kind == .ed2k && task.status != .completed {
            message = String(localized: "未完成的电驴分块会随任务移除；已完成的文件可以保留。")
        } else {
            message = String(localized: "只删除任务会保留下载文件，任务记录可在“最近删除”中恢复。")
        }
        present(title: String(localized: "删除「\(task.name)」？"), message: message,
                recordAction: permanent ? String(localized: "彻底删除记录") : String(localized: "只删除任务"),
                allowsDeletingFiles: true) { deleteFiles in
            guard let current = model.tasks.first(where: { $0.id == task.id }), current.deletedAt == task.deletedAt else { return }
            if deleteFiles {
                guard let coordinator = model.coordinator else {
                    model.deletionIssue = String(localized: "下载引擎未运行")
                    return
                }
                await coordinator.remove(task.id, deleteFiles: true)
            } else if permanent {
                model.removeRecord(task.id)
            } else {
                model.remove(task.id)
            }
        }
    }

    static func confirmCompleted(in model: AppModel) {
        let ids = Set(model.tasks.filter { $0.deletedAt == nil && $0.status == .completed }.map(\.id))
        guard !ids.isEmpty else { return }
        present(title: String(localized: "清除 \(ids.count) 条已完成的任务？"),
                message: String(localized: "只删除任务会保留下载文件，任务记录可在“最近删除”中恢复。"),
                recordAction: String(localized: "只删除任务"), allowsDeletingFiles: true) { deleteFiles in
            if let coordinator = model.coordinator {
                for id in ids {
                    guard model.tasks.contains(where: { $0.id == id && $0.deletedAt == nil && $0.status == .completed }) else { continue }
                    await coordinator.remove(id, deleteFiles: deleteFiles)
                }
            } else if deleteFiles {
                model.deletionIssue = String(localized: "下载引擎未运行")
            } else {
                for id in ids where model.tasks.contains(where: { $0.id == id && $0.status == .completed }) {
                    model.trashRecord(id)
                }
            }
        }
    }

    static func confirmMissing(count: Int, cleanup: @escaping @MainActor () async -> Void) {
        present(title: String(localized: "清理 \(count) 条缺失记录？"),
                message: String(localized: "将当前列表中找不到文件的记录移到“最近删除”，30 天内可恢复。"),
                recordAction: String(localized: "清理记录"), allowsDeletingFiles: false) { _ in await cleanup() }
    }

    private static func present(title: String, message: String, recordAction: String, allowsDeletingFiles: Bool,
                                action: @escaping @MainActor (Bool) async -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = allowsDeletingFiles
            ? message + "\n" + String(localized: "选“同时删除文件”会移除下载内容，并彻底删除任务记录。")
            : message
        let cancel = alert.addButton(withTitle: String(localized: "取消"))
        alert.addButton(withTitle: recordAction)
        if allowsDeletingFiles {
            alert.addButton(withTitle: String(localized: "同时删除文件")).hasDestructiveAction = true
        }
        alert.window.defaultButtonCell = cancel.cell as? NSButtonCell
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            switch response {
            case .alertSecondButtonReturn: Task { await action(false) }
            case .alertThirdButtonReturn where allowsDeletingFiles: Task { await action(true) }
            default: break
            }
        }
        if let parent = NSApp.keyWindow ?? NSApp.mainWindow, parent.isVisible && parent.attachedSheet == nil {
            alert.beginSheetModal(for: parent, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }
}
