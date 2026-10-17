import Foundation
import MuleeCore
import Testing
@testable import Mulee

@Suite @MainActor struct VolumeAvailabilityMonitorTests {
    private final class Probe: DownloadVolumeProbing {
        var available = true
        var identifier = "volume-a"
        var fails = false
        var missingDirectories: Set<URL> = []
        func volume(for directory: URL) throws -> DownloadVolume? {
            if fails { throw CocoaError(.fileReadUnknown) }
            if missingDirectories.contains(directory) { return nil }
            return available ? DownloadVolume(url: directory, identifier: identifier) : nil
        }
    }

    @Test func disconnectReconnectAndManualPauseAreIndependent() async throws {
        let storage = try TemporaryDefaults(prefix: "VolumeMonitor-")
        defer { storage.clean() }
        let settings = SettingsModel(defaults: storage.defaults)
        var first = MockData.tasks[0]
        first.status = .downloading
        var second = MockData.tasks[1]
        second.status = .paused
        let model = AppModel(tasks: [first, second], preventsSleepWhileDownloading: false)
        let probe = Probe()
        let monitor = VolumeAvailabilityMonitor(model: model, settings: settings, probe: probe)
        await monitor.refresh()
        probe.available = false
        await monitor.refresh()
        #expect(model.tasks[0].pauseReason == .volumeUnavailable)
        #expect(model.tasks[1].pauseReason == nil)
        model.pause(first.id)
        probe.available = true
        await monitor.refresh()
        #expect(model.tasks.allSatisfy { $0.status == .paused })
        #expect(model.tasks[0].pauseReason == nil)
        model.resume(first.id)
        #expect(model.tasks[0].status == .downloading)
        #expect(TaskPresentation(task: first).statusTitle != String(localized: "保存位置所在的磁盘已断开"))
    }

    @Test func diskProtectionAndUnavailableVolumeBothMustClear() async throws {
        let storage = try TemporaryDefaults(prefix: "VolumeAndDisk-")
        defer { storage.clean() }
        let settings = SettingsModel(defaults: storage.defaults)
        var task = MockData.tasks[0]
        task.status = .downloading
        let model = AppModel(tasks: [task], preventsSleepWhileDownloading: false)
        let probe = Probe()
        let monitor = VolumeAvailabilityMonitor(model: model, settings: settings, probe: probe)
        var free: Int64 = 9_000_000_000
        let disk = DiskReserveMonitor(model: model, settings: settings, volume: { $0 }, capacity: { _ in free })
        await monitor.refresh()
        await disk.refresh()
        probe.available = false
        await monitor.refresh()
        #expect(model.automaticPauseReasons(for: model.tasks[0]) == [.diskSpace, .volumeUnavailable])
        probe.available = true
        await monitor.refresh()
        #expect(model.tasks[0].status == .paused)
        #expect(model.tasks[0].pauseReason == .diskSpace)
        free = 12_000_000_000
        await disk.refresh(force: true)
        #expect(model.tasks[0].status == .downloading)
        #expect(model.automaticPauseReasons(for: model.tasks[0]).isEmpty)
    }

    @Test func startupMissingVolumeAndProbeFailureDoNotResumeOthers() async throws {
        let storage = try TemporaryDefaults(prefix: "VolumeStartup-")
        defer { storage.clean() }
        let settings = SettingsModel(defaults: storage.defaults)
        var task = MockData.tasks[0]
        task.status = .downloading
        let model = AppModel(tasks: [task], preventsSleepWhileDownloading: false)
        let probe = Probe()
        probe.available = false
        let monitor = VolumeAvailabilityMonitor(model: model, settings: settings, probe: probe)
        await monitor.refresh()
        #expect(model.tasks[0].status == .paused)
        probe.available = true
        probe.fails = true
        await monitor.refresh()
        #expect(model.tasks[0].pauseReason == .volumeUnavailable)
        probe.fails = false
        await monitor.refresh()
        #expect(model.tasks[0].status == .downloading)
    }

    @Test func replacementVolumeAtSamePathDoesNotResumeOriginalTask() async throws {
        let storage = try TemporaryDefaults(prefix: "VolumeIdentity-")
        defer { storage.clean() }
        var task = MockData.tasks[0]
        task.status = .downloading
        let model = AppModel(tasks: [task], preventsSleepWhileDownloading: false)
        let probe = Probe()
        let monitor = VolumeAvailabilityMonitor(model: model, settings: SettingsModel(defaults: storage.defaults), probe: probe)
        await monitor.refresh()
        probe.identifier = "other-volume"
        await monitor.refresh()
        #expect(model.tasks[0].pauseReason == .volumeUnavailable)
        probe.identifier = "volume-a"
        await monitor.refresh()
        #expect(model.tasks[0].status == .downloading)
    }

    @Test func everyWriteDirectoryMustReturnBeforeResuming() async throws {
        let storage = try TemporaryDefaults(prefix: "VolumeDirectories-")
        defer { storage.clean() }
        let first = URL(filePath: "/tmp/source-volume")
        let second = URL(filePath: "/tmp/destination-volume")
        var task = MockData.tasks[0]
        task.kind = .ed2k
        task.status = .downloading
        task.writeDirectories = [first, second]
        var other = MockData.tasks[1]
        other.status = .downloading
        other.writeDirectories = [URL(filePath: "/tmp/other-volume")]
        let model = AppModel(tasks: [task, other], preventsSleepWhileDownloading: false)
        let probe = Probe()
        let monitor = VolumeAvailabilityMonitor(model: model, settings: SettingsModel(defaults: storage.defaults), probe: probe)
        await monitor.refresh()
        probe.missingDirectories = [first, second]
        await monitor.refresh()
        #expect(model.tasks[0].pauseReason == .volumeUnavailable)
        #expect(model.tasks[1].status == .downloading)
        probe.missingDirectories = [second]
        await monitor.refresh()
        #expect(model.tasks[0].status == .paused)
        probe.missingDirectories = []
        await monitor.refresh()
        #expect(model.tasks[0].status == .waitingForSources)
    }

    @Test func completedEngineSnapshotCannotBypassOtherProtectionReason() async throws {
        var task = MockData.tasks[0]
        task.engineTaskID = "protected-task"
        task.status = .paused
        task.totalBytes = 100
        task.receivedBytes = 10
        task.pauseReason = .volumeUnavailable
        let model = AppModel(tasks: [task], preventsSleepWhileDownloading: false)
        model.automaticPauseStore.insert(.volumeUnavailable, for: task)
        model.automaticPauseStore.insert(.diskSpace, for: task)
        let engine = FakeEngine(kind: task.kind)
        let coordinator = DownloadCoordinator(model: model, engines: [engine])
        await coordinator.start(options: EngineOptions(downloadDirectory: URL(filePath: "/tmp")))
        await engine.setSnapshots([EngineTaskSnapshot(
            engineTaskID: "protected-task", name: task.name, totalBytes: 100, receivedBytes: 100,
            downloadRate: 0, uploadRate: 0, status: .completed, connections: 0,
            savePath: nil, sourceURL: nil, errorMessage: nil
        )])
        await coordinator.poll()
        #expect(model.tasks[0].status == .paused)
        await model.resumeAutomatically(task.id, reason: .volumeUnavailable)
        #expect(model.tasks[0].status == .paused)
        #expect(model.tasks[0].pauseReason == .diskSpace)
        await coordinator.stop()
    }

    @Test func rememberedVolumeIdentityIsCheckedAfterRestart() async throws {
        let storage = try TemporaryDefaults(prefix: "VolumeRestart-")
        defer { storage.clean() }
        var task = MockData.tasks[0]
        task.status = .downloading
        let model = AppModel(tasks: [task], preventsSleepWhileDownloading: false)
        let settings = SettingsModel(defaults: storage.defaults)
        let probe = Probe()
        let first = VolumeAvailabilityMonitor(model: model, settings: settings, probe: probe, defaults: storage.defaults)
        await first.refresh()
        probe.identifier = "other-volume"
        let restarted = VolumeAvailabilityMonitor(model: model, settings: settings, probe: probe, defaults: storage.defaults)
        await restarted.refresh()
        #expect(model.tasks[0].pauseReason == .volumeUnavailable)
        probe.identifier = "volume-a"
        await restarted.refresh()
        #expect(model.tasks[0].status == .downloading)
    }

    @Test func multipleReasonsAndManualIntentSurviveStoreReload() throws {
        let storage = try TemporaryDefaults(prefix: "PauseStore-")
        defer { storage.clean() }
        let task = MockData.tasks[0]
        let store = QueuePauseStore(defaults: storage.defaults)
        store.insert(.volumeUnavailable, for: task)
        store.insert(.diskSpace, for: task)
        store.setManuallyPaused(true, for: task)
        let restored = QueuePauseStore(defaults: storage.defaults)
        #expect(restored.systemReasons(for: task) == [.volumeUnavailable, .diskSpace])
        #expect(restored.isManuallyPaused(task))
        restored.remove(.volumeUnavailable, for: task)
        #expect(restored.displayReason(for: task) == .diskSpace)
    }
}
