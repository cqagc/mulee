import Foundation
import MuleeCore

/// 排序只处理列表数据，不改变任务模型中的队列位置。
nonisolated struct TaskSort: Equatable {
    enum Key: String, CaseIterable {
        case added
        case name
        case size
        case progress
        case speed
        case status

        var title: String {
            switch self {
            case .added: String(localized: "添加时间")
            case .name: String(localized: "名称")
            case .size: String(localized: "大小")
            case .progress: String(localized: "进度")
            case .speed: String(localized: "速度")
            case .status: String(localized: "状态")
            }
        }
    }

    static let defaultValue = "added.descending"
    var key: Key
    var ascending: Bool

    init(key: Key, ascending: Bool) {
        self.key = key
        self.ascending = ascending
    }

    init(_ value: String) {
        let parts = value.split(separator: ".")
        guard parts.count == 2, let key = Key(rawValue: String(parts[0])),
              ["ascending", "descending"].contains(parts[1]) else {
            self.init(key: .added, ascending: false)
            return
        }
        self.init(key: key, ascending: parts[1] == "ascending")
    }

    var value: String { key.rawValue + (ascending ? ".ascending" : ".descending") }

    func sorted(_ tasks: [DownloadTask]) -> [DownloadTask] {
        // 名称和状态的排序键只生成一次，避免每次比较都做本地化或字符串转换。
        let names = key == .name ? tasks.map { $0.name.lowercased() } : []
        let statuses = key == .status ? tasks.map { $0.status.rawValue } : []
        let progress = key == .progress ? tasks.map { $0.fractionCompleted ?? -1 } : []
        let indices = tasks.indices.sorted { lhs, rhs in
            let comparison: ComparisonResult
            switch key {
            case .added:
                if let a = tasks[lhs].createdAt, let b = tasks[rhs].createdAt {
                    comparison = compare(a, b)
                } else if tasks[lhs].createdAt != nil {
                    comparison = .orderedDescending
                } else if tasks[rhs].createdAt != nil {
                    comparison = .orderedAscending
                } else {
                    // 旧历史本来就是新的在上；反向索引充当缺失的添加时间。
                    comparison = compare(rhs, lhs)
                }
            case .name: comparison = compare(names[lhs], names[rhs])
            case .size: comparison = compare(tasks[lhs].totalBytes ?? -1, tasks[rhs].totalBytes ?? -1)
            case .progress: comparison = compare(progress[lhs], progress[rhs])
            case .speed: comparison = compare(tasks[lhs].downloadRate, tasks[rhs].downloadRate)
            case .status: comparison = compare(statuses[lhs], statuses[rhs])
            }
            if comparison == .orderedSame { return lhs < rhs }
            return comparison == (ascending ? .orderedAscending : .orderedDescending)
        }
        return indices.map { tasks[$0] }
    }

    private func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        lhs == rhs ? .orderedSame : lhs < rhs ? .orderedAscending : .orderedDescending
    }
}
