import Foundation
import MuleeCore

/// 保留正在下载的名额；等待来源与做种不占下载名额。
nonisolated enum GlobalConcurrencyPolicy {
    static func isStalled(_ task: DownloadTask, lastActivity: Date?, now: Date, minutes: Int) -> Bool {
        guard minutes > 0, task.status == .downloading, task.downloadRate <= 0,
              let lastActivity else { return false }
        return now.timeIntervalSince(lastActivity) >= Double(minutes) * 60
    }

    static func occupiesSlot(_ task: DownloadTask, yielded: Set<DownloadTask.ID> = []) -> Bool {
        task.engineTaskID != nil && [.downloading, .queued].contains(task.status) && !yielded.contains(task.id)
    }

    static func admitted(
        tasks: [DownloadTask], limit: Int, yielded: Set<DownloadTask.ID> = [],
        recovered: Set<DownloadTask.ID> = []
    ) -> Set<DownloadTask.ID> {
        let candidates = tasks.filter { occupiesSlot($0, yielded: yielded) }
        let running = candidates.filter { $0.status == .downloading }
        let capacity = max(1, limit)
        let kept = running.filter { recovered.contains($0.id) }
            + running.filter { !recovered.contains($0.id) }.prefix(capacity)
        let queued = orderedQueue(candidates.filter { $0.status == .queued })
        return Set(kept.map(\.id) + queued.prefix(max(0, capacity - kept.count)).map(\.id))
    }

    static func orderedQueue(_ tasks: [DownloadTask]) -> [DownloadTask] {
        tasks.enumerated().sorted { lhs, rhs in
            let a = lhs.element
            let b = rhs.element
            if a.priority != b.priority { return a.priority.rank < b.priority.rank }
            let first = a.queuePosition ?? 0
            let second = b.queuePosition ?? 0
            if first != second { return first < second }
            // 同批任务保留原有数组顺序；列表排序不会重排模型。
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    static func moving(tasks: [DownloadTask], id: DownloadTask.ID, toFront: Bool) -> [DownloadTask] {
        guard tasks.contains(where: { $0.id == id && $0.deletedAt == nil }) else { return tasks }
        var indices = tasks.indices.filter { tasks[$0].deletedAt == nil && tasks[$0].id != id }.sorted {
            let a = tasks[$0].queuePosition ?? 0
            let b = tasks[$1].queuePosition ?? 0
            return a == b ? $0 < $1 : a < b
        }
        guard let target = tasks.firstIndex(where: { $0.id == id }) else { return tasks }
        indices.insert(target, at: toFront ? 0 : indices.count)
        var result = tasks
        // 重新编号避免反复移到最前或最后造成整数溢出。
        for (position, index) in indices.enumerated() { result[index].queuePosition = Int64(position) }
        return result
    }
}
