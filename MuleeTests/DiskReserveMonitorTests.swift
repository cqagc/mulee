import Foundation
import MuleeCore
import Testing
@testable import Mulee

@Suite @MainActor struct DiskReserveMonitorTests {
    @Test func deduplicatesVolumesWarnsPausesAndUsesHysteresis() async throws {
        let defaults = try TemporaryDefaults(prefix: "DiskReserve-")
        defer { defaults.clean() }
        let settings = SettingsModel(defaults: defaults.defaults)
        let links = LinkParser.parse("https://example.com/a\nhttps://example.com/b\nhttps://example.com/c\nhttps://example.com/d")
        var tasks = links.map { DownloadTask(link: $0, autoExtract: false) }
        tasks[0].savePath = URL(filePath: "/tmp/a/file")
        tasks[1].savePath = URL(filePath: "/tmp/b/file")
        tasks[2].status = .paused
        tasks[3].kind = .bittorrent
        tasks[3].status = .seeding
        let model = AppModel(tasks: tasks, preventsSleepWhileDownloading: false)
        var available: Int64 = 12_000_000_000
        var reads = 0
        var now = Date(timeIntervalSince1970: 0)
        let monitor = DiskReserveMonitor(model: model, settings: settings, now: { now }, volume: { _ in URL(filePath: "/") }) { _ in
            reads += 1
            return available
        }

        await monitor.refresh()
        #expect(reads == 1)
        #expect(model.diskReserveWarnings.count == 1)
        #expect(model.diskReserveWarnings[0].isPaused == false)
        available = 10_000_000_000
        await monitor.refresh()
        #expect(reads == 1)
        now += 5
        await monitor.refresh()
        #expect(model.tasks[0].pauseReason == .diskSpace)
        #expect(model.tasks[1].status == .paused)
        #expect(model.tasks[2].pauseReason == nil)
        #expect(model.tasks[3].status == .seeding)
        available = 11_000_000_000
        now += 5
        await monitor.refresh()
        #expect(model.tasks[0].status == .paused)
        available += 1
        now += 5
        await monitor.refresh()
        #expect(model.tasks[0].status == .downloading)
        #expect(model.tasks[1].pauseReason == nil)
        #expect(model.tasks[2].status == .paused)
        #expect(model.tasks[3].status == .seeding)
    }

    @Test func knownSizeCheckUsesStrictBoundaryWithoutPausingOrNotifying() throws {
        let defaults = try TemporaryDefaults(prefix: "DiskReservePreflight-")
        defer { defaults.clean() }
        let settings = SettingsModel(defaults: defaults.defaults)
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        var available: Int64 = 12_000_000_000
        let monitor = DiskReserveMonitor(model: model, settings: settings, volume: { _ in URL(filePath: "/") }) { _ in available }
        let directory = URL(filePath: "/tmp/selected")
        #expect(try !monitor.requiresConfirmation(forKnownBytes: 2_000_000_000, in: directory))
        #expect(try monitor.requiresConfirmation(forKnownBytes: 2_000_000_001, in: directory))
        available = 9_000_000_000
        #expect(try monitor.requiresConfirmation(forKnownBytes: 0, in: directory))
        settings.diskReserveEnabled = false
        #expect(try !monitor.requiresConfirmation(forKnownBytes: Int64.max, in: directory))
        #expect(model.diskReserveWarnings.isEmpty)
    }

    @Test func multiVolumeTaskWaitsForBothTemporaryAndDestinationVolumes() async throws {
        let defaults = try TemporaryDefaults(prefix: "DiskReserveTemporary-")
        defer { defaults.clean() }
        let settings = SettingsModel(defaults: defaults.defaults)
        var task = MockData.tasks[0]
        task.kind = .ed2k
        task.writeDirectories = [URL(filePath: "/tmp/source-volume"), URL(filePath: "/tmp/target-volume")]
        let model = AppModel(tasks: [task], preventsSleepWhileDownloading: false)
        var source: Int64 = 9_000_000_000
        var target: Int64 = 20_000_000_000
        let monitor = DiskReserveMonitor(model: model, settings: settings, volume: { $0 }) { volume in
            volume.lastPathComponent == "source-volume" ? source : target
        }
        await monitor.refresh()
        #expect(model.tasks[0].pauseReason == .diskSpace)
        source = 12_000_000_000
        target = 10_000_000_000
        await monitor.refresh(force: true)
        #expect(model.tasks[0].status == .paused)
        target = 11_000_000_001
        await monitor.refresh(force: true)
        #expect(model.tasks[0].status == .waitingForSources)
        #expect(model.tasks[0].pauseReason == nil)
    }

    @Test func independentVolumesAndDisablingProtectionResumeOnlyOwnedPauses() async throws {
        let defaults = try TemporaryDefaults(prefix: "DiskReserveVolumes-")
        defer { defaults.clean() }
        let settings = SettingsModel(defaults: defaults.defaults)
        var first = MockData.tasks[0]
        first.status = .downloading
        first.savePath = URL(filePath: "/tmp/volume-a/file")
        var second = MockData.tasks[1]
        second.status = .downloading
        second.savePath = URL(filePath: "/tmp/volume-b/file")
        let model = AppModel(tasks: [first, second], preventsSleepWhileDownloading: false)
        let monitor = DiskReserveMonitor(model: model, settings: settings, volume: { $0 }) { volume in
            volume.lastPathComponent == "volume-a" ? 9_000_000_000 : 50_000_000_000
        }
        await monitor.refresh()
        #expect(model.tasks[0].status == .paused)
        #expect(model.tasks[1].status == .downloading)
        model.pause(first.id)
        settings.diskReserveEnabled = false
        await monitor.refresh(force: true)
        #expect(model.tasks[0].status == .paused)
        #expect(model.tasks[0].pauseReason == nil)
        #expect(model.diskReserveWarnings.isEmpty)
    }

    @Test func pauseReasonIsCompatibleWithOldHistoryAndSurvivesSnapshots() throws {
        var task = MockData.tasks[0]
        task.status = .paused
        task.pauseReason = .diskSpace
        let encoded = try JSONEncoder().encode(task)
        #expect(try JSONDecoder().decode(DownloadTask.self, from: encoded).pauseReason == .diskSpace)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "pauseReason")
        object.removeValue(forKey: "writeDirectories")
        let old = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(DownloadTask.self, from: old).pauseReason == nil)
        task.engineTaskID = "task-1"
        let snapshot = EngineTaskSnapshot(
            engineTaskID: "task-1", name: task.name, totalBytes: 100, receivedBytes: 1,
            downloadRate: 0, uploadRate: 0, status: .downloading, connections: 0,
            savePath: task.savePath, sourceURL: nil, errorMessage: nil,
            writeDirectories: [URL(filePath: "/tmp/writing")]
        )
        let merged = EngineSnapshotMerger.merge(tasks: [task], snapshots: [task.kind: [snapshot]], now: Date())
        #expect(merged.first?.status == .paused)
        #expect(merged.first?.pauseReason == .diskSpace)
        #expect(merged.first?.writeDirectories == [URL(filePath: "/tmp/writing")])
        #expect(TaskPresentation(task: task).statusTitle == String(localized: "因磁盘空间不足已暂停"))
        var finished = snapshot
        finished.status = .completed
        let completed = EngineSnapshotMerger.merge(tasks: [task], snapshots: [task.kind: [finished]], now: Date())
        #expect(completed.first?.status == .completed)
        #expect(completed.first?.pauseReason == nil)
    }

    @Test func extractionWaitsForReserveAndRecoversWithoutStartingEarly() async throws {
        let context = try ExtractionTestContext()
        var available: Int64 = 9_000_000_000
        let monitor = DiskReserveMonitor(model: context.model, settings: context.settings, volume: { _ in URL(filePath: "/") }) { _ in available }
        context.model.tasks = [try context.task(status: .completed)]
        context.coordinator.start()
        try await context.waitUntil { context.model.tasks[0].pauseReason == .diskSpace }
        #expect(await context.extractor.calls.isEmpty)
        #expect(!monitor.canStartExtraction(at: context.root))
        available = 11_000_000_001
        await monitor.refresh(force: true)
        try await context.waitUntil { context.model.tasks[0].postDownload.extractionState == .succeeded }
        #expect(await context.extractor.calls.count == 1)
        try await context.clean()
    }

    @Test(arguments: [false, true])
    func runningExtractionStopsAtReserveAndCanBeRetriedManually(multipart: Bool) async throws {
        let context = try ExtractionTestContext(suspends: true)
        var available: Int64 = 20_000_000_000
        let monitor = DiskReserveMonitor(model: context.model, settings: context.settings, volume: { _ in URL(filePath: "/") }) { _ in available }
        let task = try context.task(multipart ? "fixture.7z.001" : "fixture.zip", status: .completed)
        context.model.tasks = multipart ? [task, try context.task("fixture.7z.002", status: .completed)] : [task]
        context.coordinator.start()
        try await context.waitUntil { await context.extractor.calls.count == 1 }

        available = 10_000_000_000
        await monitor.refresh(force: true)
        #expect(context.model.diskReserveWarnings.first?.isPaused == true)
        #expect(context.model.tasks[0].status == .completed)
        #expect(context.model.tasks[0].postDownload.extractionState == .cancelled)
        #expect(context.model.tasks[0].postDownload.extractionFailure?.contains("因磁盘空间不足未完成解压") == true)
        #expect(FileManager.default.fileExists(atPath: task.savePath!.path))

        available = 20_000_000_000
        await monitor.refresh(force: true)
        #expect(await context.extractor.calls.count == 1)
        // 修复前先释放仍在运行的假解压器，保证失败测试也能清理。
        await context.extractor.release()
        try await context.waitUntil { context.model.tasks[0].status == .completed }
        context.coordinator.requestExtraction(context.model.tasks.last!.id)
        try await context.waitUntil { await context.extractor.calls.count == 2 }
        await context.extractor.release()
        try await context.waitUntil { context.model.tasks.allSatisfy { $0.postDownload.extractionState == .succeeded } }
        try await context.clean()
    }

    @Test func persistedProtectionKeepsHysteresisAfterRestart() async throws {
        let defaults = try TemporaryDefaults(prefix: "DiskReserveRestart-")
        defer { defaults.clean() }
        let settings = SettingsModel(defaults: defaults.defaults)
        var task = MockData.tasks[0]
        task.status = .paused
        task.pauseReason = .diskSpace
        let model = AppModel(tasks: [task], preventsSleepWhileDownloading: false)
        let monitor = DiskReserveMonitor(model: model, settings: settings, volume: { _ in URL(filePath: "/") }) { _ in 10_500_000_000 }
        await monitor.refresh()
        #expect(model.tasks[0].status == .paused)
        settings.diskReserveEnabled = false
        await monitor.refresh(force: true)
        #expect(model.tasks[0].status == .downloading)
        #expect(model.tasks[0].pauseReason == nil)
    }

    @Test func notificationActionManuallyExtractsWhenAutoExtractionIsOff() async throws {
        let context = try ExtractionTestContext()
        context.settings.autoExtract = false
        context.model.tasks = [try context.task(status: .completed)]
        context.coordinator.start()
        let center = DownloadNotificationCenterSpy()
        let service = NotificationService(model: context.model, settings: context.settings, center: center)
        let id = try #require(context.model.tasks.first?.id)
        service.handleAction(NotificationService.extractAction, taskIDs: [id.uuidString])
        try await context.waitUntil { context.model.tasks[0].postDownload.extractionState == .succeeded }
        #expect(await context.extractor.calls.count == 1)
        #expect(!context.settings.autoExtract)
        try await context.clean()
    }

    @Test func coordinatorRoutesProtectionThroughEngineAndPreservesManualPauses() async throws {
        let defaults = try TemporaryDefaults(prefix: "DiskReserveEngine-")
        defer { defaults.clean() }
        let settings = SettingsModel(defaults: defaults.defaults)
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        let engine = FakeEngine()
        let coordinator = DownloadCoordinator(model: model, engines: [engine])
        await coordinator.start(options: EngineOptions(downloadDirectory: URL(filePath: "/tmp")))
        await coordinator.add(links: LinkParser.parse("https://example.com/file"), autoExtract: false)
        _ = try #require(model.tasks.first?.id)
        var available: Int64 = 9_000_000_000
        let monitor = DiskReserveMonitor(model: model, settings: settings, volume: { _ in URL(filePath: "/") }) { _ in available }
        await monitor.refresh()
        #expect(await engine.pausedIDs.contains("task-1"))
        #expect(model.tasks.first?.pauseReason == .diskSpace)
        available = 11_000_000_001
        await monitor.refresh(force: true)
        #expect(model.tasks.first?.pauseReason == nil)
        #expect(await engine.resumedIDs.contains("task-1"))
        await coordinator.stop()
    }
}
