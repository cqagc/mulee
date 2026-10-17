import Foundation
import MuleeCore

/// 在引擎暂停前写入意图；重启时不能把调度暂停当成用户暂停。
final class QueuePauseStore {
    private let defaults: UserDefaults?
    private let key = "downloadScheduling.pauseReasons"
    private var reasons: [String: String]
    private let systemKey = "downloadScheduling.systemPauseReasons"
    private let manualKey = "downloadScheduling.manualPauseIDs"
    private var system: [String: [String]]
    private var manual: Set<String>

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        reasons = defaults?.dictionary(forKey: key) as? [String: String] ?? [:]
        system = defaults?.dictionary(forKey: systemKey) as? [String: [String]] ?? [:]
        manual = Set(defaults?.stringArray(forKey: manualKey) ?? [])
    }

    func reason(for task: DownloadTask) -> String? {
        identity(task).flatMap { reasons[$0] }
    }

    func set(_ reason: String?, for task: DownloadTask) {
        guard let id = identity(task), reasons[id] != reason else { return }
        reasons[id] = reason
        defaults?.set(reasons, forKey: key)
    }

    func systemReasons(for task: DownloadTask) -> Set<DownloadTask.PauseReason> {
        var values = Set((system[task.id.uuidString] ?? []).compactMap(DownloadTask.PauseReason.init(rawValue:)))
        if let reason = task.pauseReason { values.insert(reason) }
        return values
    }

    func insert(_ reason: DownloadTask.PauseReason, for task: DownloadTask) {
        var values = systemReasons(for: task)
        values.insert(reason)
        save(values, for: task)
    }

    func remove(_ reason: DownloadTask.PauseReason, for task: DownloadTask) {
        var values = systemReasons(for: task)
        values.remove(reason)
        save(values, for: task)
    }

    func displayReason(for task: DownloadTask) -> DownloadTask.PauseReason? {
        let values = systemReasons(for: task)
        return [.volumeUnavailable, .diskSpace, .systemSleep, .schedule].first { values.contains($0) }
    }

    func setManuallyPaused(_ paused: Bool, for task: DownloadTask) {
        if paused {
            save(systemReasons(for: task), for: task)
            manual.insert(task.id.uuidString)
        } else {
            manual.remove(task.id.uuidString)
        }
        defaults?.set(Array(manual), forKey: manualKey)
    }

    func isManuallyPaused(_ task: DownloadTask) -> Bool {
        manual.contains(task.id.uuidString)
    }

    private func save(_ values: Set<DownloadTask.PauseReason>, for task: DownloadTask) {
        system[task.id.uuidString] = values.map(\.rawValue).sorted()
        defaults?.set(system, forKey: systemKey)
    }

    private func identity(_ task: DownloadTask) -> String? {
        task.engineTaskID.map { task.kind.rawValue + ":" + $0 }
    }
}
