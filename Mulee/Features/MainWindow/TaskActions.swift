import AppKit
import MuleeCore

/// 列表菜单和详情栏共用的系统操作。
enum TaskActions {
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
