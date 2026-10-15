import MuleeCore

/// 保留正在下载的名额；等待来源与做种不占下载名额。
nonisolated enum GlobalConcurrencyPolicy {
    static func occupiesSlot(_ task: DownloadTask) -> Bool {
        task.engineTaskID != nil && [.downloading, .queued].contains(task.status)
    }

    static func admitted(tasks: [DownloadTask], limit: Int) -> Set<DownloadTask.ID> {
        let candidates = tasks.filter(occupiesSlot)
        let ordered = candidates.filter { $0.status == .downloading }
            + candidates.filter { $0.status == .queued }
        return Set(ordered.prefix(max(1, limit)).map(\.id))
    }
}
