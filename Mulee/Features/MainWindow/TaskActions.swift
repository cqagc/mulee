import AppKit
import MuleeCore

/// 列表菜单和详情栏共用的系统操作。
enum TaskActions {
    @MainActor
    static func editTags(_ task: DownloadTask, model: AppModel) {
        let alert = NSAlert()
        alert.messageText = String(localized: "编辑标签")
        alert.informativeText = String(localized: "用逗号分隔多个标签；清空可移除全部标签。")
        let field = NSTextField(string: (task.tags ?? []).joined(separator: ", "))
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        field.setAccessibilityLabel(String(localized: "标签"))
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "保存"))
        alert.addButton(withTitle: String(localized: "取消"))
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn { model.setTags(task.id, text: field.stringValue) }
    }

    static func copyLink(_ task: DownloadTask) {
        _ = SystemClipboard.write(task.sourceLink)
    }

    static func localURL(for task: DownloadTask) -> URL {
        task.savePath ?? URL.downloadsDirectory.appending(path: "Mulee", directoryHint: .isDirectory)
            .appending(path: task.name, directoryHint: .inferFromPath)
    }

    static func reveal(_ task: DownloadTask) {
        let url = localURL(for: task)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            let directory = task.savePath?.deletingLastPathComponent()
                ?? URL.downloadsDirectory.appending(path: "Mulee", directoryHint: .isDirectory)
            NSWorkspace.shared.open(task.savePath != nil || FileManager.default.fileExists(atPath: directory.path) ? directory : .downloadsDirectory)
        }
    }
}
