import Darwin
import Foundation
import MuleeCore

extension AppModel {
    static func canOfferRedownload(_ task: DownloadTask) -> Bool {
        if task.kind == .bittorrent, task.needsFileRelink == true { return task.deletedAt == nil }
        return task.fileMissing == true && task.deletedAt == nil
            && ([.completed, .seeding].contains(task.status) || (task.completedAt != nil && [.failed, .paused].contains(task.status)))
            && ![.queued, .extracting].contains(task.postDownload.extractionState)
    }

    func redownloadMissingFile(_ id: UUID) async {
        guard redownloadingIDs.insert(id).inserted else { return }
        defer { redownloadingIDs.remove(id) }
        do {
            guard let coordinator else { throw EngineError.notRunning }
            try await coordinator.redownloadMissingFile(id)
        } catch is CancellationError {
            return
        } catch {
            redownloadIssue = EngineStatusPresentation.errorMessage(error)
        }
    }

    func missingFileRecordCandidates(in ids: Set<UUID>) -> Set<UUID> {
        Set(tasks.compactMap { task in
            guard ids.contains(task.id), !redownloadingIDs.contains(task.id), task.deletedAt == nil, task.status == .completed,
                  task.fileMissing == true, task.savePath?.isFileURL == true, task.pauseReason != .volumeUnavailable,
                  ![.queued, .extracting, .waitingForVolumes].contains(task.postDownload.extractionState)
            else { return nil }
            return task.id
        })
    }

    /// 只在显示清理入口及执行清理时检查磁盘。没有权限和卷断开都不能证明文件已删除。
    func confirmedMissingFileRecords(in candidates: Set<UUID>) -> Set<UUID> {
        Set(tasks.compactMap { task in
            guard candidates.contains(task.id), let path = task.savePath,
                  !automaticPauseReasons(for: task).contains(.volumeUnavailable),
                  (try? DiskReserveMonitor.volumeURL(path.deletingLastPathComponent())) != nil else { return nil }
            var attributes = stat()
            if lstat(path.path, &attributes) == 0 {
                return FileTracker.isInTrash(path) ? task.id : nil
            }
            return errno == ENOENT ? task.id : nil
        })
    }

    @discardableResult
    func trashMissingFileRecords(_ ids: Set<UUID>) async -> Int {
        var removed = 0
        for id in ids {
            // 清理前重新解析书签；文件可能已改名、被移走或刚从废纸篓放回。
            refreshTrackedFile(id)
            let candidates = missingFileRecordCandidates(in: [id])
            guard confirmedMissingFileRecords(in: candidates).contains(id) else { continue }
            if let coordinator {
                // 沿用按协议移除引擎记录及屏蔽迟到快照的逻辑。
                await coordinator.remove(id, deleteFiles: false)
            } else {
                trashRecord(id)
            }
            if tasks.first(where: { $0.id == id })?.deletedAt != nil { removed += 1 }
        }
        return removed
    }
}
