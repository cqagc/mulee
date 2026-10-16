import Foundation
import MuleeCore

/// 按卷采样，避免同一磁盘上的多个保存目录重复读取容量。
@MainActor
final class DiskReserveMonitor {
    struct Warning: Equatable, Identifiable {
        let volume: URL
        let available: Int64
        let reserve: Int64
        let isPaused: Bool
        var id: URL { volume }
    }

    private let model: AppModel
    private let settings: SettingsModel
    private let volume: (URL) throws -> URL
    private let capacity: (URL) throws -> Int64
    private let now: () -> Date
    private var lastCheck: Date?
    private var worker: Task<Void, Never>?
    private var checking = false
    private var protectedVolumes: Set<URL> = []

    init(
        model: AppModel, settings: SettingsModel, now: @escaping () -> Date = Date.init,
        volume: @escaping (URL) throws -> URL = DiskReserveMonitor.volumeURL,
        capacity: @escaping (URL) throws -> Int64 = DiskReserveMonitor.availableCapacity
    ) {
        self.model = model
        self.settings = settings
        self.now = now
        self.volume = volume
        self.capacity = capacity
        model.diskReserveMonitor = self
    }

    var reserveBytes: Int64 { Int64(min(500, max(1, settings.diskReserveGB))) * 1_000_000_000 }

    func start() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
            }
        }
    }

    func stop() {
        worker?.cancel()
        worker = nil
    }

    isolated deinit { worker?.cancel() }

    func refresh(force: Bool = false) async {
        guard !checking else { return }
        let date = now()
        guard force || lastCheck == nil || date.timeIntervalSince(lastCheck ?? date) >= 5 else { return }
        lastCheck = date
        checking = true
        defer { checking = false }
        let tasks = model.tasks.filter { Self.needsProtection($0) || $0.pauseReason == .diskSpace }
        var byVolume: [URL: [DownloadTask]] = [:]
        var taskVolumes: [DownloadTask.ID: Set<URL>] = [:]
        var unknownVolumes: Set<DownloadTask.ID> = []
        for task in tasks {
            let fallback = task.savePath?.deletingLastPathComponent()
                ?? model.coordinator?.diskProtectionDirectory(for: task.id)
                ?? URL(filePath: settings.saveDirectory)
            let directories = task.writeDirectories.flatMap { $0.isEmpty ? nil : $0 } ?? [fallback]
            for directory in directories {
                guard let key = try? volume(directory).standardizedFileURL else {
                    unknownVolumes.insert(task.id)
                    continue
                }
                if taskVolumes[task.id, default: []].insert(key).inserted {
                    byVolume[key, default: []].append(task)
                }
            }
        }
        var warnings: [Warning] = []
        var blockedVolumes: Set<URL> = []
        var readableVolumes: Set<URL> = []
        for key in byVolume.keys.sorted(by: { $0.path < $1.path }) {
            guard !Task.isCancelled else { return }
            guard let available = try? capacity(key) else { continue }
            readableVolumes.insert(key)
            let wasProtected = protectedVolumes.contains(key)
                || (byVolume[key] ?? []).contains { $0.pauseReason == .diskSpace }
            let blocked = settings.diskReserveEnabled && (available <= reserveBytes
                || (wasProtected && available <= reserveBytes + 1_000_000_000))
            if blocked {
                blockedVolumes.insert(key)
                if !wasProtected {
                    model.notificationService?.sendSystem(
                        title: String(localized: "因磁盘空间不足已暂停"),
                        body: String(localized: "清理磁盘、换保存目录或调低保护容量后继续。")
                    )
                }
            }
            if settings.diskReserveEnabled, blocked || available <= reserveBytes + 2_000_000_000 {
                warnings.append(Warning(volume: key, available: available, reserve: reserveBytes, isPaused: blocked))
            }
        }
        protectedVolumes = blockedVolumes
        // 一个任务可能同时写入临时卷和目标卷；必须全部恢复后才能继续。
        for task in tasks {
            guard !Task.isCancelled else { return }
            let keys = taskVolumes[task.id] ?? []
            if !keys.isDisjoint(with: blockedVolumes), Self.needsProtection(task) {
                await pause(task)
            } else if task.pauseReason == .diskSpace,
                      !settings.diskReserveEnabled || (!unknownVolumes.contains(task.id)
                        && !keys.isEmpty && keys.isSubset(of: readableVolumes)
                        && keys.isDisjoint(with: blockedVolumes)) {
                await resume(task)
            }
        }
        model.diskReserveWarnings = warnings
    }

    /// 添加前只判断，不暂停任务或发送通知；等于保护线时不要求额外确认。
    func requiresConfirmation(forKnownBytes size: Int64, in directory: URL) throws -> Bool {
        guard settings.diskReserveEnabled else { return false }
        let available = max(0, try capacity(volume(directory)))
        guard available >= reserveBytes else { return true }
        return max(0, size) > available - reserveBytes
    }

    /// 解压前独立读取目标卷；检查通过才允许解压器创建产物。
    func canStartExtraction(at directory: URL) -> Bool {
        guard settings.diskReserveEnabled else { return true }
        guard let key = try? volume(directory).standardizedFileURL, let available = try? capacity(key) else { return false }
        guard available <= reserveBytes else { return true }
        if protectedVolumes.insert(key).inserted {
            model.notificationService?.sendSystem(
                title: String(localized: "因磁盘空间不足已暂停"),
                body: String(localized: "清理磁盘、换保存目录或调低保护容量后继续。")
            )
        }
        model.diskReserveWarnings.removeAll { $0.volume == key }
        model.diskReserveWarnings.append(Warning(volume: key, available: available, reserve: reserveBytes, isPaused: true))
        return false
    }

    private func pause(_ task: DownloadTask) async {
        if task.postDownload.extractionState == .queued, task.status == .completed { return }
        if let coordinator = model.coordinator {
            await coordinator.pauseForDiskSpace(task.id)
        } else if let index = model.tasks.firstIndex(where: { $0.id == task.id }) {
            model.tasks[index].pauseReason = .diskSpace
            model.tasks[index].status = .paused
            model.tasks[index].downloadRate = 0
            model.tasks[index].uploadRate = 0
        }
    }

    private func resume(_ task: DownloadTask) async {
        if task.postDownload.extractionState == .queued {
            guard let index = model.tasks.firstIndex(where: { $0.id == task.id }) else { return }
            model.tasks[index].pauseReason = nil
            model.tasks[index].status = .completed
        } else if let coordinator = model.coordinator {
            await coordinator.resumeAfterDiskSpace(task.id)
        } else if let index = model.tasks.firstIndex(where: { $0.id == task.id }) {
            model.tasks[index].pauseReason = nil
            model.tasks[index].status = task.kind == .ed2k ? .waitingForSources : .downloading
        }
    }

    private static func needsProtection(_ task: DownloadTask) -> Bool {
        [.downloading, .queued, .waitingForSources, .postProcessing].contains(task.status)
    }

    nonisolated static func volumeURL(_ directory: URL) throws -> URL {
        var existing = directory
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            existing.deleteLastPathComponent()
        }
        return try existing.resourceValues(forKeys: [.volumeURLKey]).volume ?? existing
    }

    nonisolated static func availableCapacity(_ volume: URL) throws -> Int64 {
        let values = try volume.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let bytes = values.volumeAvailableCapacityForImportantUsage else {
            throw CocoaError(.fileReadUnknown)
        }
        return bytes
    }
}
