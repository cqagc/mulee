import Foundation
import MuleeCore

/// 只保存耐久字段；引擎会话负责恢复进行中的下载进度。
@MainActor
final class TaskHistoryStore {
    private struct Document: Codable {
        var version: Int
        var tasks: [DownloadTask]
    }

    struct LoadResult {
        var tasks: [DownloadTask]
        var issue: String?
    }

    let fileURL: URL
    private var lastSavedTasks: [DownloadTask]?
    private var pendingTasks: [DownloadTask]?
    private var saveTask: Task<Void, Never>?
    private var canSave = true

    init(directory: URL = URL.applicationSupportDirectory.appending(path: "Mulee", directoryHint: .isDirectory)) {
        fileURL = directory.appending(path: "tasks.json")
    }

    func load() -> LoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            lastSavedTasks = []
            return LoadResult(tasks: [], issue: nil)
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            canSave = false
            return LoadResult(tasks: [], issue: String(localized: "无法读取任务历史：\(error.localizedDescription)"))
        }
        do {
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.version == 1 else {
                return quarantine(reason: String(localized: "不支持的任务历史版本：\(document.version)"))
            }
            let tasks = Self.durableTasks(document.tasks)
            lastSavedTasks = tasks
            return LoadResult(tasks: tasks, issue: nil)
        } catch {
            return quarantine(reason: String(localized: "任务历史文件损坏：\(error.localizedDescription)"))
        }
    }

    /// 纯函数：瞬时统计和未完成任务的字节进度不参与写盘判断。
    nonisolated static func needsSave(tasks: [DownloadTask], lastSaved: [DownloadTask]?) -> Bool {
        guard let lastSaved else { return true }
        return durableTasks(tasks) != durableTasks(lastSaved)
    }

    nonisolated static func durableTasks(_ tasks: [DownloadTask]) -> [DownloadTask] {
        tasks.map { task in
            var task = task
            task.downloadRate = 0
            task.uploadRate = 0
            task.estimatedTimeRemaining = nil
            if ![.completed, .failed, .engineUnavailable].contains(task.status) {
                task.receivedBytes = 0
            }
            task.postDownload.extractProgress = nil
            switch task.detail {
            case .http:
                task.detail = .http(connections: 0)
            case .bittorrent(let fileCount, let selectedFileCount, _, _):
                task.detail = .bittorrent(fileCount: fileCount, selectedFileCount: selectedFileCount, peerCount: 0, shareRatio: 0)
            case .ed2k(let hash, var longTail):
                longTail.queueRank = nil
                longTail.sourceCount = 0
                longTail.completeSourceCount = 0
                longTail.lastCompleteSourceSeen = nil
                longTail.activeTransferDuration = .zero
                longTail.dailySourceSightings = []
                task.detail = .ed2k(hash: hash, longTail: longTail)
            case .video:
                break
            }
            return task
        }
    }

    func scheduleSave(tasks: [DownloadTask], onError: @escaping @MainActor (String) -> Void) {
        let durable = Self.durableTasks(tasks)
        guard Self.needsSave(tasks: durable, lastSaved: lastSavedTasks) else {
            saveTask?.cancel()
            saveTask = nil
            pendingTasks = nil
            return
        }
        // 每秒的快照不应把已经排定的写盘无限推迟。
        guard pendingTasks != durable else { return }
        saveTask?.cancel()
        pendingTasks = durable
        saveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            guard let self, let pendingTasks = self.pendingTasks else { return }
            self.pendingTasks = nil
            self.saveTask = nil
            do {
                try self.save(tasks: pendingTasks)
            } catch {
                onError(String(localized: "无法保存任务历史：\(error.localizedDescription)"))
            }
        }
    }

    /// 退出时立即落盘，绕过防抖；内容未变仍不重复写入。
    @discardableResult
    func flush(tasks: [DownloadTask]) throws -> Bool {
        saveTask?.cancel()
        saveTask = nil
        pendingTasks = nil
        return try save(tasks: tasks)
    }

    @discardableResult
    private func save(tasks: [DownloadTask]) throws -> Bool {
        guard canSave else { return false }
        let durable = Self.durableTasks(tasks)
        guard Self.needsSave(tasks: durable, lastSaved: lastSavedTasks) else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Document(version: 1, tasks: durable))
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        lastSavedTasks = durable
        return true
    }

    private func quarantine(reason: String) -> LoadResult {
        let timestamp = Int(Date.now.timeIntervalSince1970 * 1_000)
        let backup = fileURL.deletingLastPathComponent().appending(path: "tasks.json.corrupt-\(timestamp)-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: fileURL, to: backup)
            lastSavedTasks = []
            return LoadResult(tasks: [], issue: String(localized: "\(reason)。已备份为 \(backup.lastPathComponent)，从空列表开始。"))
        } catch {
            // 备份失败时禁止覆盖原文件。
            canSave = false
            return LoadResult(tasks: [], issue: String(localized: "\(reason)。备份失败，已保留原文件并停用历史写入：\(error.localizedDescription)"))
        }
    }
}
