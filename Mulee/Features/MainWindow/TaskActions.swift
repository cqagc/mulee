import AppKit
import MuleeCore

/// 列表菜单和详情栏共用的系统操作。
enum TaskActions {
    static func copyLink(_ task: DownloadTask) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(task.sourceLink, forType: .string)
    }

    static func localURL(for task: DownloadTask) -> URL {
        // TODO: 引擎接入后改用任务真实保存路径。
        URL.downloadsDirectory.appending(path: "Mulee", directoryHint: .isDirectory)
            .appending(path: task.name, directoryHint: .inferFromPath)
    }

    static func reveal(_ task: DownloadTask) {
        let url = localURL(for: task)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            let directory = URL.downloadsDirectory.appending(path: "Mulee", directoryHint: .isDirectory)
            NSWorkspace.shared.open(FileManager.default.fileExists(atPath: directory.path) ? directory : .downloadsDirectory)
        }
    }
}
