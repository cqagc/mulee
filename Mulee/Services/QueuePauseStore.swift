import Foundation
import MuleeCore

/// 在引擎暂停前写入意图；重启时不能把调度暂停当成用户暂停。
final class QueuePauseStore {
    private let defaults: UserDefaults?
    private let key = "downloadScheduling.pauseReasons"
    private var reasons: [String: String]

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        reasons = defaults?.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    func reason(for task: DownloadTask) -> String? {
        identity(task).flatMap { reasons[$0] }
    }

    func set(_ reason: String?, for task: DownloadTask) {
        guard let id = identity(task), reasons[id] != reason else { return }
        reasons[id] = reason
        defaults?.set(reasons, forKey: key)
    }

    private func identity(_ task: DownloadTask) -> String? {
        task.engineTaskID.map { task.kind.rawValue + ":" + $0 }
    }
}
