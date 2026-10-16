import Foundation
import MuleeCore

/// 按实际写入文件发布；每次快照撤下已暂停、完成或删除的进度。
@MainActor
final class DownloadFileProgressPublisher {
    private(set) var progresses: [URL: Progress] = [:]

    func update(tasks: [DownloadTask], torrentFiles: [UUID: [TorrentFileEntry]] = [:]) {
        var active: [URL: (Int64, Int64)] = [:]
        for task in tasks where task.deletedAt == nil && task.status == .downloading {
            if task.kind == .bittorrent {
                for file in torrentFiles[task.id] ?? [] where file.priority > 0 && file.done < file.size {
                    guard let url = StreamingPlayback.fileURL(task: task, file: file) else { continue }
                    active[url] = (file.size, file.done)
                }
            } else if let url = task.savePath {
                active[url] = (task.totalBytes ?? -1, task.receivedBytes)
            }
        }
        for url in progresses.keys where active[url] == nil {
            progresses.removeValue(forKey: url)?.unpublish()
        }
        for (url, counts) in active {
            let progress: Progress
            if let existing = progresses[url] {
                progress = existing
            } else {
                progress = Progress(totalUnitCount: counts.0)
                progress.kind = .file
                progress.fileURL = url
                progress.setUserInfoObject(Progress.FileOperationKind.downloading, forKey: .fileOperationKindKey)
                progress.isCancellable = false
                progress.isPausable = false
                progresses[url] = progress
                progress.publish()
            }
            progress.totalUnitCount = counts.0
            progress.completedUnitCount = max(0, counts.1)
        }
    }

    func stop() {
        for progress in progresses.values { progress.unpublish() }
        progresses.removeAll()
    }
}
