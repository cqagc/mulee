import AppKit
import Foundation
import MuleeCore

struct DownloadVolume: Equatable {
    let url: URL
    let identifier: String
}

@MainActor
protocol DownloadVolumeProbing {
    func volume(for directory: URL) throws -> DownloadVolume?
}

struct SystemDownloadVolumeProbe: DownloadVolumeProbing {
    func volume(for directory: URL) throws -> DownloadVolume? {
        // 未挂载路径的检查与磁盘保护一致，不能退回系统卷。
        let volume = try DiskReserveMonitor.volumeURL(directory)
        let values = try volume.resourceValues(forKeys: [.volumeIdentifierKey])
        guard let identifier = values.volumeIdentifier else { return nil }
        return DownloadVolume(url: volume, identifier: String(describing: identifier))
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
              task.status != .paused || task.pauseReason != nil || !automaticPauseReasons(for: task).isEmpty else { return }
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
    private var knownVolumes: [URL: DownloadVolume] = [:]
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
            if let url = entry["url"].flatMap({ URL(string: $0) }), let identifier = entry["identifier"] {
                knownVolumes[URL(filePath: path)] = DownloadVolume(url: url, identifier: identifier)
            }
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
        defer { refreshing = false }
        for task in model.activeTasks where ![.completed, .seeding].contains(task.status) || task.postDownload.extractionState == .queued {
            let fallback = task.savePath?.deletingLastPathComponent()
                ?? model.coordinator?.diskProtectionDirectory(for: task.id) ?? URL(filePath: settings.saveDirectory)
            let directories = task.writeDirectories.flatMap { $0.isEmpty ? nil : $0 } ?? [fallback]
            var unavailable = false
            for directory in directories {
                let directory = directory.standardizedFileURL
                do {
                    guard let volume = try probe.volume(for: directory) else { unavailable = true; continue }
                    if let previous = knownVolumes[directory], previous.identifier != volume.identifier {
                        unavailable = true
                    } else if knownVolumes[directory] != volume {
                        knownVolumes[directory] = volume
                        let saved = Dictionary(uniqueKeysWithValues: knownVolumes.map { directory, volume in
                            (directory.path, ["url": volume.url.absoluteString, "identifier": volume.identifier])
                        })
                        defaults?.set(saved, forKey: volumeKey)
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
                await model.pauseAutomatically(task.id, reason: .volumeUnavailable)
            } else {
                await model.resumeAutomatically(task.id, reason: .volumeUnavailable)
            }
        }
    }
}
