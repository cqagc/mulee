import Foundation
import MuleeCore

/// 普通书签跟踪文件身份；解析失败只标记缺失，不删除历史。
enum FileTracker {
    static func capture(_ task: inout DownloadTask) {
        guard task.fileBookmark == nil, let url = task.savePath else { return }
        do {
            task.fileBookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            task.fileMissing = false
        } catch {
            task.fileMissing = !FileManager.default.fileExists(atPath: url.path)
        }
    }

    static func resolve(_ task: inout DownloadTask) {
        guard let data = task.fileBookmark else {
            capture(&task)
            return
        }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
            guard FileManager.default.fileExists(atPath: url.path) else {
                task.fileMissing = true
                return
            }
            task.savePath = url
            task.fileMissing = false
            if stale, let renewed = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                task.fileBookmark = renewed
            }
        } catch {
            task.fileMissing = true
        }
    }
}
