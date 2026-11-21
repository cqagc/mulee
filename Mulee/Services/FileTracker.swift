import Foundation
import MuleeCore

/// 普通书签跟踪文件身份；解析失败只标记缺失，不删除历史。
enum FileTracker {
    static func capture(_ task: inout DownloadTask) {
        guard task.fileBookmark == nil, let url = task.savePath else { return }
        guard FileManager.default.fileExists(atPath: url.path), !isInTrash(url) else {
            task.fileMissing = true
            return
        }
        do {
            task.fileBookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: [.fileResourceIdentifierKey, .pathKey], relativeTo: nil)
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
            guard FileManager.default.fileExists(atPath: url.path), !isInTrash(url),
                  !stale || matchesStaleBookmark(data, at: url) else {
                task.fileMissing = true
                return
            }
            task.savePath = url
            task.fileMissing = false
            if stale, let renewed = try? url.bookmarkData(options: [], includingResourceValuesForKeys: [.fileResourceIdentifierKey, .pathKey], relativeTo: nil) {
                task.fileBookmark = renewed
            }
        } catch {
            task.fileMissing = true
        }
    }

    /// macOS 可能按旧路径解析过期书签，即使同名文件的身份已经改变。
    private static func matchesStaleBookmark(_ data: Data, at url: URL) -> Bool {
        let stored = NSURL.resourceValues(forKeys: [.fileResourceIdentifierKey, .pathKey], fromBookmarkData: data)
        if let identity = stored?[.fileResourceIdentifierKey] as? NSObject {
            let current = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
            return identity.isEqual(current)
        }
        // 旧书签没有显式存储标识。若系统仍指向旧路径，不能把它更新为同名替代品。
        guard let original = stored?[.pathKey] as? String else { return false }
        return URL(filePath: original).standardizedFileURL.resolvingSymlinksInPath().path
            != url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func isInTrash(_ url: URL) -> Bool {
        var relationship = FileManager.URLRelationship.other
        try? FileManager.default.getRelationship(&relationship, of: .trashDirectory, in: [], toItemAt: url)
        return relationship == .contains || relationship == .same
    }
}
