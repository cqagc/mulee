import AppKit
import Foundation
import MuleeCore

struct DownloadVolume: Equatable {
    let url: URL
    let identifier: String

    static func directoryKey(_ directory: URL) -> String {
        var path = directory.standardizedFileURL.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    static func identity(uuid: String?, url: URL, name: String) -> String {
        if let uuid, !uuid.isEmpty { return "uuid:" + uuid.lowercased() }
        return "mount:" + directoryKey(url) + ":" + name
    }
}

@MainActor
protocol DownloadVolumeProbing {
    func volume(for directory: URL) throws -> DownloadVolume?
}

struct SystemDownloadVolumeProbe: DownloadVolumeProbing {
    func volume(for directory: URL) throws -> DownloadVolume? {
        // 未挂载路径的检查与磁盘保护一致，不能退回系统卷。
        let volume = try DiskReserveMonitor.volumeURL(directory)
        let values = try volume.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeNameKey])
        let identifier = DownloadVolume.identity(uuid: values.volumeUUIDString, url: volume, name: values.volumeName ?? volume.lastPathComponent)
        return DownloadVolume(url: volume, identifier: identifier)
    }
}

/// 使用已有暂停意图存储保存多个保护原因；显示原因只是其中优先级最高的一项。
extension AppModel {
    func automaticPauseReasons(for task: DownloadTask) -> Set<DownloadTask.PauseReason> {
        automaticPauseStore.systemReasons(for: task)
    }

    func pauseAutomatically(_ id: UUID, reason: DownloadTask.PauseReason) async {
        guard let task = tasks.first(where: { $0.id == id && $0.deletedAt == nil }),
              ![.completed, .seeding, .failed].contains(task.status) || task.postDownload.extractionState == .queued
                || (task.status == .seeding && reason == .schedule)
                || (task.status == .failed && reason == .volumeUnavailable),
              task.status != .paused || task.pauseReason != nil || !automaticPauseReasons(for: task).isEmpty
                || (reason == .volumeUnavailable && coordinator?.hasPendingVolumeWriteFailure(id) == true) else { return }
        automaticPauseStore.insert(reason, for: task)
        guard !userPausedTaskIDs.contains(id), !automaticPauseStore.isManuallyPaused(task),
              let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].pauseReason = automaticPauseStore.displayReason(for: tasks[index])
        if task.status == .paused { return }
        if let coordinator {
            await coordinator.pause(id)
        } else {
            tasks[index].status = .paused
            tasks[index].downloadRate = 0
            tasks[index].uploadRate = 0
        }
        if let current = tasks.firstIndex(where: { $0.id == id }), !userPausedTaskIDs.contains(id) {
            tasks[current].pauseReason = automaticPauseStore.displayReason(for: tasks[current])
        }
    }

    func resumeAutomatically(_ id: UUID, reason: DownloadTask.PauseReason) async {
        guard let task = tasks.first(where: { $0.id == id && $0.deletedAt == nil }),
              automaticPauseReasons(for: task).contains(reason) else { return }
        automaticPauseStore.remove(reason, for: task)
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].pauseReason = nil
        let remaining = automaticPauseStore.displayReason(for: tasks[index])
        guard !userPausedTaskIDs.contains(id), !automaticPauseStore.isManuallyPaused(task) else { return }
        tasks[index].pauseReason = remaining
        guard remaining == nil else { return }
        if task.postDownload.extractionState == .queued {
            tasks[index].status = .completed
        } else if let coordinator {
            if task.completedAt != nil, [.http, .video].contains(task.kind),
               task.totalBytes.map({ $0 > 0 && task.receivedBytes >= $0 }) == true {
                // 完成回调与断开通知可能交错；交给下一次快照完成改名和来源写入。
                tasks[index].status = .queued
                return
            }
            await coordinator.resume(id)
            if let current = tasks.firstIndex(where: { $0.id == id }), tasks[current].status == .paused,
               tasks[current].pauseReason == nil, !userPausedTaskIDs.contains(id) {
                automaticPauseStore.insert(reason, for: tasks[current])
                tasks[current].pauseReason = reason
            }
        } else {
            tasks[index].status = task.kind == .ed2k ? .waitingForSources : .downloading
        }
    }
}

@MainActor
final class VolumeAvailabilityMonitor {
    private let model: AppModel
    private let settings: SettingsModel
    private let probe: any DownloadVolumeProbing
    private let defaults: UserDefaults?
    private let volumeKey = "downloadScheduling.knownWriteVolumes"
    private var knownVolumes: [String: DownloadVolume] = [:]
    private var needsSaving = false
    private var observers: [NSObjectProtocol] = []
    private var worker: Task<Void, Never>?
    private var refreshing = false

    init(
        model: AppModel, settings: SettingsModel, probe: any DownloadVolumeProbing = SystemDownloadVolumeProbe(),
        defaults: UserDefaults? = AppEnvironment.isRunningUnitTests ? nil : .standard
    ) {
        self.model = model
        self.settings = settings
        self.probe = probe
        self.defaults = defaults
        let saved = defaults?.dictionary(forKey: volumeKey) as? [String: [String: String]] ?? [:]
        for (path, entry) in saved {
            // 旧版标识随挂载变化，忽略旧记录并在卷可用时重新记录。
            guard entry["identityVersion"] == "2", let url = entry["url"].flatMap({ URL(string: $0) }),
                  let identifier = entry["identifier"] else {
                needsSaving = true
                continue
            }
            let directory = URL(string: path).flatMap { $0.isFileURL ? $0 : nil } ?? URL(filePath: path)
            let key = DownloadVolume.directoryKey(directory)
            if key != path || knownVolumes[key] != nil { needsSaving = true }
            knownVolumes[key] = DownloadVolume(url: url, identifier: identifier)
        }
    }

    func start() {
        guard worker == nil else { return }
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in await self?.refresh() }
            })
        }
        worker = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
            }
        }
    }

    func stop() {
        worker?.cancel()
        worker = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
    }

    isolated deinit {
        worker?.cancel()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer {
            if needsSaving {
                // URL 的唯一性不保证转换后的路径唯一；持久化也显式容忍重复键。
                let saved = Dictionary(knownVolumes.map { path, volume in
                    (path, ["url": volume.url.absoluteString, "identifier": volume.identifier, "identityVersion": "2"])
                }, uniquingKeysWith: { _, latest in latest })
                defaults?.set(saved, forKey: volumeKey)
                needsSaving = false
            }
            refreshing = false
        }
        for task in model.activeTasks where ![.completed, .seeding].contains(task.status) || task.postDownload.extractionState == .queued {
            let fallback = task.savePath?.deletingLastPathComponent()
                ?? model.coordinator?.diskProtectionDirectory(for: task.id) ?? URL(filePath: settings.saveDirectory)
            let directories = task.writeDirectories.flatMap { $0.isEmpty ? nil : $0 } ?? [fallback]
            var unavailable = false
            for directory in directories {
                let key = DownloadVolume.directoryKey(directory)
                let directory = directory.standardizedFileURL
                do {
                    guard let volume = try probe.volume(for: directory) else { unavailable = true; continue }
                    if let previous = knownVolumes[key], previous.identifier != volume.identifier {
                        unavailable = true
                    } else if knownVolumes[key] != volume {
                        knownVolumes[key] = volume
                        needsSaving = true
                    }
                } catch {
                    unavailable = true
                }
            }
            if unavailable {
                if task.status == .extracting {
                    await model.extractionCoordinator?.cancelForUnavailableVolume(task.id)
                    continue
                }
                guard model.coordinator?.prepareForUnavailableVolume(task.id) != false else { continue }
                await model.pauseAutomatically(task.id, reason: .volumeUnavailable)
            } else {
                await model.resumeAutomatically(task.id, reason: .volumeUnavailable)
            }
        }
    }
}
