import Darwin
import Foundation
import MuleeCore

enum DownloadedOutput {
    private static var unidentified: EngineError {
        .invalidResponse(String(localized: "无法确认要删除的文件，已保留任务记录。"))
    }

    static func isAbsent(_ url: URL?) throws -> Bool {
        guard let url else { return true }
        guard url.isFileURL else { throw unidentified }
        _ = try DiskReserveMonitor.volumeURL(url.deletingLastPathComponent())
        var info = stat()
        if lstat(url.path, &info) == 0 { return false }
        let code = errno
        if code == ENOENT { return true }
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    static func existingURL(for task: DownloadTask) throws -> URL? {
        guard let lastPath = task.savePath else { return nil }
        var url = lastPath
        if task.fileBookmark != nil {
            var tracked = task
            FileTracker.resolve(&tracked)
            if tracked.fileMissing == true {
                if try isAbsent(lastPath) || FileTracker.isInTrash(lastPath) { return nil }
                throw unidentified
            }
            guard let current = tracked.savePath else { throw unidentified }
            url = current
        }
        if try isAbsent(url) || FileTracker.isInTrash(url) { return nil }
        guard task.fileBookmark != nil || (task.fileMissing != true && task.deletedAt == nil) else { throw unidentified }
        return url
    }

    static func validateSingleFile(_ url: URL?) throws {
        guard let url, try !isAbsent(url) else { return }
        // 不用目录名推断归属。多文件任务必须由有文件清单的引擎删除。
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw unidentified }
    }

    static func trashSingleFile(_ url: URL?) throws {
        guard let url, try !isAbsent(url) else { return }
        try validateSingleFile(url)
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}
