import Foundation
import MuleeCore
import Testing
@testable import Mulee

@Suite @MainActor struct BandwidthSchedulingTests {
    private func task(_ kind: TaskKind, _ id: String, _ status: TaskStatus, rate: Int64 = 0) -> DownloadTask {
        DownloadTask(
            name: "fixture.bin", fileExtension: "bin", kind: kind, status: status,
            totalBytes: 1_000_000, receivedBytes: 0, downloadRate: rate, uploadRate: rate,
            detail: MockData.tasks[0].detail, postDownload: PostDownloadInfo(autoExtract: false),
            sourceLink: "https://example.com/fixture.bin", engineTaskID: id
        )
    }

    @Test func globalConcurrencyExemptsLongTailAndSeeding() async {
        let http = FakeEngine()
        let bt = FakeEngine(kind: .bittorrent)
        let ed2k = FakeEngine(kind: .ed2k)
        let model = AppModel(tasks: [
            task(.http, "h", .downloading), task(.bittorrent, "bt", .downloading),
            task(.bittorrent, "seed", .seeding), task(.ed2k, "tail", .waitingForSources)
        ])
        let scheduling = DownloadScheduling(defaults: nil)
        let options = EngineOptions(downloadDirectory: URL(filePath: "/tmp"), maxConcurrentDownloads: 1)

        await scheduling.refresh(model: model, engines: [http, bt, ed2k], options: options, isCurrent: { true })

        #expect(await bt.pausedIDs == ["bt"])
        #expect(await ed2k.pausedIDs.isEmpty)
        #expect(model.tasks[1].status == .queued)
        #expect(model.tasks[2].status == .seeding)
        #expect(model.tasks[3].status == .waitingForSources)
    }

    @Test func manualPauseIsNeverAutomaticallyResumed() async {
        let engine = FakeEngine()
        let manual = task(.http, "manual", .paused)
        let queued = task(.http, "queue", .paused)
        let model = AppModel(tasks: [manual, queued])
        let scheduling = DownloadScheduling(defaults: nil)
        scheduling.userPause(manual)
        scheduling.queue(queued)
        let options = EngineOptions(downloadDirectory: URL(filePath: "/tmp"), maxConcurrentDownloads: 1)

        await scheduling.refresh(model: model, engines: [engine], options: options, isCurrent: { true })

        #expect(await engine.resumedIDs == ["queue"])
        #expect(model.tasks[0].status == .paused)
        #expect(model.tasks[1].status == .queued)
    }

    @Test func pauseReasonsSurviveRestart() throws {
        let temporaryDefaults = try TemporaryDefaults(prefix: "BandwidthQueue-")
        defer { temporaryDefaults.clean() }
        let defaults = temporaryDefaults.defaults
        let queued = task(.bittorrent, "queue", .paused)
        let manual = task(.ed2k, "manual", .paused)
        let first = QueuePauseStore(defaults: defaults)
        first.set("queue", for: queued)
        first.set("user", for: manual)

        let restored = QueuePauseStore(defaults: defaults)

        #expect(restored.reason(for: queued) == "queue")
        #expect(restored.reason(for: manual) == "user")
        restored.set(nil, for: queued)
        #expect(QueuePauseStore(defaults: defaults).reason(for: queued) == nil)
    }

    @Test func failedPauseDoesNotReleaseCapacity() async {
        let http = FakeEngine()
        let bt = FakeEngine(kind: .bittorrent)
        await bt.failOperations(with: .notRunning)
        let first = task(.http, "first", .downloading)
        let overflow = task(.bittorrent, "overflow", .downloading)
        let queued = task(.http, "queue", .paused)
        let scheduling = DownloadScheduling(defaults: nil)
        scheduling.queue(queued)
        let model = AppModel(tasks: [first, overflow, queued])
        let options = EngineOptions(downloadDirectory: URL(filePath: "/tmp"), maxConcurrentDownloads: 1)

        await scheduling.refresh(model: model, engines: [http, bt], options: options, isCurrent: { true })

        #expect(await http.resumedIDs.isEmpty)
        #expect(model.tasks[1].errorMessage != nil)
    }

    @Test func bandwidthIntervalDebounceAndSharedUpload() async throws {
        let http = FakeEngine()
        let bt = FakeEngine(kind: .bittorrent)
        let ed2k = FakeEngine(kind: .ed2k)
        let engines: [any DownloadEngine] = [http, bt, ed2k]
        let model = AppModel(tasks: [
            task(.http, "h", .downloading, rate: 500_000),
            task(.bittorrent, "bt", .downloading, rate: 100_000),
            task(.ed2k, "e", .waitingForSources, rate: 1_000)
        ])
        let scheduling = DownloadScheduling(defaults: nil)
        let options = EngineOptions(downloadDirectory: URL(filePath: "/tmp"), downloadLimit: 1_000_000, uploadLimit: 500_000)
        let now = Date(timeIntervalSince1970: 1_000)
        await scheduling.refresh(model: model, engines: engines, options: options, now: now, isCurrent: { true })
        let initialCount = await http.appliedOptions.count
        await scheduling.refresh(model: model, engines: engines, options: options, now: now.addingTimeInterval(1), isCurrent: { true })
        #expect(await http.appliedOptions.count == initialCount)
        let h = try #require(await http.appliedOptions.last)
        let b = try #require(await bt.appliedOptions.last)
        let e = try #require(await ed2k.appliedOptions.last)
        #expect(h.downloadLimit + b.downloadLimit + e.downloadLimit <= options.downloadLimit)
        #expect(b.uploadLimit + e.uploadLimit <= options.uploadLimit)
        #expect(e.uploadLimit % 1024 == 0)
        #expect(h.uploadLimit == 0)
    }

    @Test func scheduledLimitSwitchBypassesIntervalAndUnlimitedClearsCaps() async throws {
        let engine = FakeEngine()
        let model = AppModel(tasks: [task(.http, "h", .downloading)])
        let scheduling = DownloadScheduling(defaults: nil)
        var options = EngineOptions(downloadDirectory: URL(filePath: "/tmp"), downloadLimit: 20_000_000)
        let now = Date(timeIntervalSince1970: 1_000)
        await scheduling.refresh(model: model, engines: [engine], options: options, now: now, isCurrent: { true })
        options.downloadLimit = 5_000_000
        await scheduling.refresh(model: model, engines: [engine], options: options, now: now, isCurrent: { true })
        #expect(await engine.appliedOptions.last?.downloadLimit == 5_000_000)
        options.downloadLimit = 0
        await scheduling.refresh(model: model, engines: [engine], options: options, now: now, isCurrent: { true })
        #expect(await engine.appliedOptions.last?.downloadLimit == 0)
    }

    @Test func smallAllocationChangeDoesNotSendRPC() async {
        let http = FakeEngine()
        let bt = FakeEngine(kind: .bittorrent)
        let model = AppModel(tasks: [task(.http, "h", .downloading, rate: 500_000), task(.bittorrent, "b", .downloading, rate: 500_000)])
        let scheduling = DownloadScheduling(defaults: nil)
        let options = EngineOptions(downloadDirectory: URL(filePath: "/tmp"), downloadLimit: 1_000_000)
        let now = Date(timeIntervalSince1970: 1_000)
        await scheduling.refresh(model: model, engines: [http, bt], options: options, now: now, isCurrent: { true })
        let before = await http.appliedOptions.count
        model.tasks[0].downloadRate = 501_000

        await scheduling.refresh(model: model, engines: [http, bt], options: options, now: now.addingTimeInterval(3), isCurrent: { true })

        #expect(await http.appliedOptions.count == before)
    }

    @Test func coordinatorQueuesAcrossEnginesAndManualResumeWaitsForSlot() async throws {
        let http = FakeEngine()
        let bt = FakeEngine(kind: .bittorrent)
        let model = AppModel(tasks: [])
        let coordinator = DownloadCoordinator(model: model, engines: [http, bt])
        let options = EngineOptions(downloadDirectory: URL(filePath: "/tmp"), maxConcurrentDownloads: 1)
        await coordinator.start(options: options)
        let links = LinkParser.parse(
            "https://example.com/fixture.zip\nmagnet:?xt=urn:btih:0123456789012345678901234567890123456789"
        )
        await coordinator.add(links: links, autoExtract: false)
        let httpID = try #require(model.tasks.first(where: { $0.kind == .http })?.id)
        let btID = try #require(model.tasks.first(where: { $0.kind == .bittorrent })?.id)
        #expect(await bt.pausedIDs.contains("task-1"))
        #expect(await bt.resumedIDs.isEmpty)

        await coordinator.pause(btID)
        await coordinator.resume(btID)
        #expect(await bt.resumedIDs.isEmpty)
        await coordinator.pause(httpID)

        #expect(await bt.resumedIDs == ["task-1"])
        #expect(model.tasks.first(where: { $0.id == httpID })?.status == .paused)
        await coordinator.stop()
    }

    @Test func restartedSchedulerRestoresQueueReasonWithoutResumingUserPause() async throws {
        let temporaryDefaults = try TemporaryDefaults(prefix: "BandwidthRestart-")
        defer { temporaryDefaults.clean() }
        let defaults = temporaryDefaults.defaults
        let manual = task(.http, "manual", .paused)
        let queued = task(.http, "queue", .paused)
        let first = DownloadScheduling(defaults: defaults)
        first.userPause(manual)
        first.queue(queued)
        let model = AppModel(tasks: [manual, queued])
        let engine = FakeEngine()
        let restarted = DownloadScheduling(defaults: defaults)

        await restarted.refresh(
            model: model, engines: [engine], options: EngineOptions(downloadDirectory: URL(filePath: "/tmp")),
            isCurrent: { true }
        )

        #expect(await engine.resumedIDs == ["queue"])
        #expect(model.tasks[0].status == .paused)
    }

    @Test func lateVideoStartupReceivesReservedQuota() async throws {
        let engine = FakeEngine()
        let model = AppModel(tasks: [task(.http, "h", .downloading, rate: 1_000_000)])
        let scheduling = DownloadScheduling(defaults: nil)
        let options = EngineOptions(downloadDirectory: URL(filePath: "/tmp"), downloadLimit: 1_000_000)
        _ = scheduling.startupOptions(options, kind: .http, kinds: [.http, .video])
        _ = scheduling.startupOptions(options, kind: .video, kinds: [.http, .video])

        await scheduling.refresh(model: model, engines: [engine], options: options, isCurrent: { true })
        let late = scheduling.startupOptions(options, kind: .video, kinds: [.http, .video])
        let running = try #require(await engine.appliedOptions.last)

        #expect(late.downloadLimit > 0)
        #expect(late.downloadLimit + running.downloadLimit <= options.downloadLimit)
    }

}
