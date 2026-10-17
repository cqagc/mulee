import Foundation
import MuleeCore
import Testing
@testable import Mulee

@Suite @MainActor struct VolumeAvailabilityMonitorTests {
    private final class Probe: DownloadVolumeProbing {
        var available = true
        var identifier = "mount-a"
        var mountedUUIDs = ["mount-a": "volume-a", "mount-b": "volume-a"]
        var uuid: String? {
            get { mountedUUIDs[identifier] }
            set { mountedUUIDs[identifier] = newValue }
        }
        var fails = false
        var missingDirectories: Set<URL> = []
        func volume(for directory: URL) throws -> DownloadVolume? {
            if fails { throw CocoaError(.fileReadUnknown) }
            if missingDirectories.contains(directory) { return nil }
            return available ? DownloadVolume(url: directory, identifier: DownloadVolume.identity(uuid: uuid, url: directory, name: "Example disk")) : nil
        }
    }

    @Test func equivalentDirectoriesAndLegacyRecordsPersistOneCanonicalKey() async throws {
        let storage = try TemporaryDefaults(prefix: "VolumeEquivalentDirectories-")
        defer { storage.clean() }
        let path = "/tmp/example-volume/downloads"
        let first = try #require(URL(string: "file:///tmp/example-volume/downloads"))
        let second = URL(filePath: path, directoryHint: .isDirectory)
        let third = try #require(URL(string: "file:///tmp/example-volume/./downloads/"))
        #expect(first != second)
        storage.defaults.set([
            path: ["url": first.absoluteString, "identifier": "legacy-mount"],
            path + "/": ["url": second.absoluteString, "identifier": "uuid:volume-a", "identityVersion": "2"],
            "/tmp/example-volume/./downloads/": ["url": third.absoluteString, "identifier": "uuid:volume-a", "identityVersion": "2"]
        ], forKey: "downloadScheduling.knownWriteVolumes")
        var task = MockData.tasks[0]
        task.status = .downloading
        task.writeDirectories = [first, second, third]
        var failed = MockData.tasks[1]
        failed.status = .failed
        failed.writeDirectories = [second]
        let model = AppModel(tasks: [task, failed], preventsSleepWhileDownloading: false)
        let probe = Probe()
        let monitor = VolumeAvailabilityMonitor(model: model, settings: SettingsModel(defaults: storage.defaults),
                                                probe: probe, defaults: storage.defaults)
        await monitor.refresh()
        await monitor.refresh()
        #expect(model.tasks[0].status == .downloading)
        #expect(model.tasks[1].status == .failed)
        let saved = try #require(storage.defaults.dictionary(forKey: "downloadScheduling.knownWriteVolumes") as? [String: [String: String]])
        #expect(Set(saved.keys) == [path])
        #expect(saved[path]?["identifier"] == "uuid:volume-a")
        #expect(saved[path]?["identityVersion"] == "2")
        let restarted = VolumeAvailabilityMonitor(model: model, settings: SettingsModel(defaults: storage.defaults),
                                                  probe: probe, defaults: storage.defaults)
        await restarted.refresh()
        #expect(model.tasks[0].status == .downloading)
    }

    @Test func canonicalDirectoryKeysKeepRootAndCollapseTrailingSlashes() throws {
        #expect(DownloadVolume.directoryKey(URL(filePath: "/")) == "/")
        let plain = try #require(URL(string: "file:///tmp/example-volume/downloads"))
        let aliased = try #require(URL(string: "file://localhost/tmp/example-volume/other/../downloads/"))
        #expect(DownloadVolume.directoryKey(plain) == DownloadVolume.directoryKey(aliased))
        #expect(DownloadVolume.identity(uuid: nil, url: plain, name: "Example")
            == DownloadVolume.identity(uuid: nil, url: aliased, name: "Example"))
    }

    @Test func unavailableEquivalentDirectoriesDoNotDuplicatePersistedKeys() async throws {
        let storage = try TemporaryDefaults(prefix: "VolumeEquivalentMissing-")
        defer { storage.clean() }
        let path = "/tmp/example-volume/downloads"
        let directory = URL(filePath: path, directoryHint: .isDirectory)
        storage.defaults.set([
            path: ["url": directory.absoluteString, "identifier": "uuid:volume-a", "identityVersion": "2"],
            path + "/": ["url": directory.absoluteString, "identifier": "uuid:volume-a", "identityVersion": "2"]
        ], forKey: "downloadScheduling.knownWriteVolumes")
        var task = MockData.tasks[0]
        task.status = .downloading
        task.writeDirectories = [directory, try #require(URL(string: "file:///tmp/example-volume/downloads"))]
        let model = AppModel(tasks: [task], preventsSleepWhileDownloading: false)
        let probe = Probe()
        probe.available = false
        let monitor = VolumeAvailabilityMonitor(model: model, settings: SettingsModel(defaults: storage.defaults),
                                                probe: probe, defaults: storage.defaults)
        await monitor.refresh()
        #expect(model.tasks[0].pauseReason == .volumeUnavailable)
        let saved = try #require(storage.defaults.dictionary(forKey: "downloadScheduling.knownWriteVolumes"))
        #expect(Set(saved.keys) == [path])
        probe.available = true
        await monitor.refresh()
        #expect(model.tasks[0].status == .downloading)
    }

    @Test(arguments: [TaskKind.http, .bittorrent, .video])
    func writeFailureBeforeUnmountIsResubmittedAfterReconnect(kind: TaskKind) async throws {
        let storage = try TemporaryDefaults(prefix: "VolumeWriteRace-")
        defer { storage.clean() }
        let source: String
        switch kind {
        case .bittorrent: source = "magnet:?xt=urn:btih:" + String(repeating: "a", count: 40)
        case .video: source = "https://www.youtube.com/watch?v=Example0001"
        default: source = "https://example.org/example.bin"
        }
        let link = try #require(LinkParser.parse(source).first)
        let directory = URL(filePath: "/tmp/example-volume/downloads")
        var task = DownloadTask(link: link, autoExtract: false)
        task.status = .downloading
        task.engineTaskID = "failed-write"
        task.savePath = directory.appendingPathComponent("example.bin")
        task.writeDirectories = [directory]
        let model = AppModel(tasks: [task], preventsSleepWhileDownloading: false)
        let engine = FakeEngine(kind: kind)
        let probe = Probe()
        var time = Date(timeIntervalSince1970: 1_000)
        let coordinator = DownloadCoordinator(model: model, engines: [engine], volumeProbe: probe, now: { time })
        await coordinator.start(options: EngineOptions(downloadDirectory: directory))
        let monitor = VolumeAvailabilityMonitor(model: model, settings: SettingsModel(defaults: storage.defaults), probe: probe)
        await monitor.refresh()
        await engine.setSnapshots([EngineTaskSnapshot(
            engineTaskID: "failed-write", name: "example.bin", totalBytes: 100, receivedBytes: 30,
            downloadRate: 0, uploadRate: 0, status: .failed, connections: 0, savePath: task.savePath,
            sourceURL: nil, errorMessage: "write error", writeDirectories: [directory], isFileWriteFailure: true
        )])
        await coordinator.poll()
        #expect(model.tasks[0].status == .paused)
        #expect(model.tasks[0].errorMessage == nil)
        time += 15
        probe.available = false
        await monitor.refresh()
        #expect(model.tasks[0].pauseReason == .volumeUnavailable)
        #expect(model.tasks[0].requiresVolumeResubmission == true)
        let restored = try JSONDecoder().decode(DownloadTask.self, from: JSONEncoder().encode(model.tasks[0]))
        #expect(restored.requiresVolumeResubmission == true)
        probe.available = true
        await monitor.refresh()
        #expect(model.tasks[0].pauseReason == nil)
        #expect(model.tasks[0].requiresVolumeResubmission == nil)
        #expect(model.tasks[0].engineTaskID != "failed-write")
        #expect(await engine.queuedLinks == [link])
        let submittedDirectories = await engine.directories
        #expect(submittedDirectories.compactMap { $0?.path } == [directory.path])
        #expect(await engine.removedIDs == ["failed-write"])
        #expect(await engine.deletesFiles == [false])
        #expect(!(await engine.resumedIDs).contains("failed-write"))
        await coordinator.stop()
    }

    @Test(arguments: [true, false])
    func expiredOrUnrelatedFailureDoesNotBecomeVolumePause(writeFailure: Bool) async throws {
        let storage = try TemporaryDefaults(prefix: "VolumeFailureDeadline-")
        defer { storage.clean() }
        var task = MockData.tasks[0]
        task.status = .downloading
        task.engineTaskID = "expired-write"
        let model = AppModel(tasks: [task], preventsSleepWhileDownloading: false)
        let engine = FakeEngine()
        let probe = Probe()
        probe.available = writeFailure
        var time = Date(timeIntervalSince1970: 1_000)
        let coordinator = DownloadCoordinator(model: model, engines: [engine], volumeProbe: probe, now: { time })
        await coordinator.start(options: EngineOptions(downloadDirectory: URL(filePath: "/tmp/example-volume")))
        await engine.setSnapshots([EngineTaskSnapshot(
            engineTaskID: "expired-write", name: "example.bin", totalBytes: 100, receivedBytes: 30,
            downloadRate: 0, uploadRate: 0, status: .failed, connections: 0, savePath: nil,
            sourceURL: nil, errorMessage: "example failure", isFileWriteFailure: writeFailure
        )])
        await coordinator.poll()
        if writeFailure { #expect(model.tasks[0].status == .paused) }
        else { #expect(model.tasks[0].status == .failed) }
        time += 15.01
        await coordinator.poll()
        #expect(model.tasks[0].status == .failed)
        probe.available = false
        let monitor = VolumeAvailabilityMonitor(model: model, settings: SettingsModel(defaults: storage.defaults), probe: probe)
        await monitor.refresh()
        #expect(model.tasks[0].status == .failed)
        #expect(model.tasks[0].pauseReason == nil)
        await coordinator.stop()
    }

    @Test func offlineFailureRecoveryRespectsManualPauseAndRetriesSubmissionFailure() async throws {
        let storage = try TemporaryDefaults(prefix: "VolumeRecoveryIntent-")
        defer { storage.clean() }
        let link = try #require(LinkParser.parse("https://example.org/example.bin").first)
        var task = DownloadTask(link: link, autoExtract: false)
        task.engineTaskID = "offline-failure"
        task.status = .downloading
        let model = AppModel(tasks: [task], preventsSleepWhileDownloading: false)
        let engine = FakeEngine()
        let probe = Probe()
        probe.available = false
        let coordinator = DownloadCoordinator(model: model, engines: [engine], volumeProbe: probe)
        await coordinator.start(options: EngineOptions(downloadDirectory: URL(filePath: "/tmp/example-volume")))
        await engine.setSnapshots([EngineTaskSnapshot(
            engineTaskID: "offline-failure", name: "example.bin", totalBytes: 100, receivedBytes: 30,
            downloadRate: 0, uploadRate: 0, status: .failed, connections: 0, savePath: nil,
            sourceURL: nil, errorMessage: "write error"
        )])
        await coordinator.poll()
        #expect(model.tasks[0].pauseReason == .volumeUnavailable)
        model.pause(task.id)
        probe.available = true
        let monitor = VolumeAvailabilityMonitor(model: model, settings: SettingsModel(defaults: storage.defaults), probe: probe)
        await monitor.refresh()
        #expect(model.tasks[0].status == .paused)
        #expect(await engine.addedLinks.isEmpty)
        model.userPausedTaskIDs.remove(task.id)
        model.automaticPauseStore.setManuallyPaused(false, for: model.tasks[0])
        await engine.failOperations(with: .launchFailed("example failure"))
        await coordinator.resume(task.id)
        #expect(model.tasks[0].status == .paused)
        #expect(model.tasks[0].requiresVolumeResubmission == true)
        await engine.failOperations(with: nil)
        await coordinator.resume(task.id)
        #expect(await engine.addedLinks == [link])
        await coordinator.stop()
    }

    @Test func remountKeepsUUIDDespiteChangedMountIdentifier() async throws {
        let storage = try TemporaryDefaults(prefix: "VolumeRemount-")
        defer { storage.clean() }
        var task = MockData.tasks[0]
        task.status = .downloading
        let model = AppModel(tasks: [task], preventsSleepWhileDownloading: false)
        let probe = Probe()
        let monitor = VolumeAvailabilityMonitor(model: model, settings: SettingsModel(defaults: storage.defaults), probe: probe)
        await monitor.refresh()
        probe.available = false
        await monitor.refresh()
        #expect(model.tasks[0].pauseReason == .volumeUnavailable)
        probe.identifier = "mount-b"
        probe.available = true
        await monitor.refresh()
        #expect(model.tasks[0].status == .downloading)
        #expect(model.tasks[0].pauseReason == nil)
    }

    @Test func legacyIdentityIsRerecordedAndUUIDLessVolumesUsePathAndName() async throws {
        let storage = try TemporaryDefaults(prefix: "VolumeLegacy-")
        defer { storage.clean() }
        var task = MockData.tasks[0]
        task.status = .paused
        task.pauseReason = .volumeUnavailable
        let directory = URL(filePath: "/tmp/example-volume/downloads")
        task.savePath = directory.appendingPathComponent("example.bin")
        task.writeDirectories = [directory]
        storage.defaults.set([directory.path: ["url": directory.absoluteString, "identifier": "old-mount"]], forKey: "downloadScheduling.knownWriteVolumes")
        let model = AppModel(tasks: [task], preventsSleepWhileDownloading: false)
        let probe = Probe()
        probe.uuid = nil
        let monitor = VolumeAvailabilityMonitor(model: model, settings: SettingsModel(defaults: storage.defaults), probe: probe, defaults: storage.defaults)
        await monitor.refresh()
        #expect(model.tasks[0].status == .downloading)
        let saved = try #require(storage.defaults.dictionary(forKey: "downloadScheduling.knownWriteVolumes") as? [String: [String: String]])
        #expect(saved[directory.path]?["identityVersion"] == "2")
        #expect(DownloadVolume.identity(uuid: nil, url: directory, name: "Example") == DownloadVolume.identity(uuid: "", url: directory, name: "Example"))
        #expect(DownloadVolume.identity(uuid: nil, url: directory, name: "Example") != DownloadVolume.identity(uuid: nil, url: directory, name: "Other"))
        #expect(DownloadVolume.identity(uuid: nil, url: directory, name: "Example") != DownloadVolume.identity(uuid: nil, url: directory.appendingPathComponent("other"), name: "Example"))
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
        probe.uuid = "other-volume"
        await monitor.refresh()
        #expect(model.tasks[0].pauseReason == .volumeUnavailable)
        probe.uuid = "volume-a"
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
        probe.uuid = "other-volume"
        let restarted = VolumeAvailabilityMonitor(model: model, settings: settings, probe: probe, defaults: storage.defaults)
        await restarted.refresh()
        #expect(model.tasks[0].pauseReason == .volumeUnavailable)
        probe.uuid = "volume-a"
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
