import Foundation
import MuleeCore
import Testing
@testable import Mulee

@Suite @MainActor struct TaskLimitTests {
    private func task(_ kind: TaskKind, id: String = "fixture") -> DownloadTask {
        DownloadTask(
            name: "fixture.bin", fileExtension: "bin", kind: kind, status: .paused,
            totalBytes: 100, receivedBytes: 0, detail: .http(connections: 0),
            postDownload: PostDownloadInfo(autoExtract: false), sourceLink: "https://example.org/file.bin",
            engineTaskID: id
        )
    }

    @Test func taskAndGlobalLimitsAreDispatchedIndependentlyAndRestored() async throws {
        let http = FakeEngine()
        let bt = FakeEngine(kind: .bittorrent)
        var h = task(.http)
        h.downloadLimit = 500_000
        h.uploadLimit = 999
        var b = task(.bittorrent)
        b.downloadLimit = 250_000
        b.uploadLimit = 100_000
        let model = AppModel(tasks: [h, b], preventsSleepWhileDownloading: false)
        let options = EngineOptions(downloadDirectory: URL(filePath: "/tmp"), downloadLimit: 50_000, uploadLimit: 25_000)
        let scheduler = DownloadScheduling(defaults: nil)
        scheduler.queue(h)
        scheduler.queue(b)
        await scheduler.refresh(model: model, engines: [http, bt], options: options, isCurrent: { true })
        #expect(await http.taskLimits.last?.download == 500_000)
        #expect(await http.taskLimits.last?.upload == 0)
        #expect(await bt.taskLimits.last?.download == 250_000)
        #expect(await bt.taskLimits.last?.upload == 100_000)
        let total = try #require(await http.appliedOptions.last?.downloadLimit)
            + #require(await bt.appliedOptions.last?.downloadLimit)
        #expect(total <= options.downloadLimit)
        #expect(await bt.appliedOptions.last?.uploadLimit == 25_000)
        await scheduler.refresh(model: model, engines: [http, bt], options: options, isCurrent: { true })
        #expect(await http.taskLimits.count == 1)
        model.tasks[0].downloadLimit = nil
        await scheduler.refresh(model: model, engines: [http, bt], options: options, isCurrent: { true })
        #expect(await http.taskLimits.last?.download == 0)
        model.tasks[0].engineTaskID = "replacement"
        await scheduler.refresh(model: model, engines: [http, bt], options: options, isCurrent: { true })
        #expect(await http.taskLimits.last?.id == "replacement")
        let beforeCacheChange = await http.taskLimits.count
        var cacheOptions = options
        cacheOptions.diskCacheMegabytes = 64
        await scheduler.refresh(model: model, engines: [http, bt], options: cacheOptions, isCurrent: { true })
        #expect(await http.taskLimits.count == beforeCacheChange + 1)
        let count = await http.taskLimits.count
        scheduler.reset()
        await scheduler.refresh(model: model, engines: [http, bt], options: options, isCurrent: { true })
        #expect(await http.taskLimits.count == count + 1)
    }

    @Test func failedLimitsKeepQueuedTaskPausedAndRetry() async {
        let engine = FakeEngine()
        await engine.failOperations(with: .notRunning)
        let pending = task(.http)
        let model = AppModel(tasks: [pending], preventsSleepWhileDownloading: false)
        let scheduler = DownloadScheduling(defaults: nil)
        scheduler.queue(pending)
        let options = EngineOptions(downloadDirectory: URL(filePath: "/tmp"))
        await scheduler.refresh(model: model, engines: [engine], options: options, isCurrent: { true })
        #expect(await engine.resumedIDs.isEmpty)
        #expect(model.tasks[0].errorMessage != nil)
        await engine.failOperations(with: nil)
        await scheduler.refresh(model: model, engines: [engine], options: options, isCurrent: { true })
        #expect(await engine.taskLimits.count == 1)
        #expect(await engine.resumedIDs == ["fixture"])
    }

    @Test func coordinatorNormalizesLimitsAndIgnoresUnsupportedTasks() async throws {
        let http = FakeEngine()
        let video = FakeEngine(kind: .video)
        let h = task(.http)
        let v = task(.video)
        let model = AppModel(tasks: [h, v], preventsSleepWhileDownloading: false)
        let coordinator = DownloadCoordinator(model: model, engines: [http, video])
        coordinator.setTaskLimits(h.id, download: -1, upload: 100)
        #expect(model.tasks[0].downloadLimit == nil)
        #expect(model.tasks[0].uploadLimit == nil)
        coordinator.setTaskLimits(h.id, download: Int64.max, upload: nil)
        #expect(model.tasks[0].downloadLimit == Int64(Int32.max))
        coordinator.setTaskLimits(v.id, download: 100, upload: 100)
        #expect(model.tasks[1].downloadLimit == nil)
        await coordinator.start(options: EngineOptions(downloadDirectory: URL(filePath: "/tmp")))
        #expect(await http.taskLimits.last?.download == Int64(Int32.max))
        #expect(await video.taskLimits.isEmpty)
        await coordinator.stop()
    }
}
