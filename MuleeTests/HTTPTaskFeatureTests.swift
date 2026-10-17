import Foundation
import MuleeCore
import Testing
@testable import Mulee

@Suite @MainActor struct HTTPTaskFeatureTests {
    @Test(arguments: ["meta4", "metalink"])
    func metalinkOpensAndDropsIntoTheDraftWithoutStartingDownloads(_ ext: String) throws {
        let file = URL(filePath: "/tmp/example [1-3] files.\(ext)")
        let request = try #require(OpenURLRequest.parse(file, detectPagePassword: false))
        #expect(request.links.count == 1)
        #expect(request.links.first?.kind == .http)
        #expect(NewTaskModel.droppedURLText(file) == file.path)
        let draft = NewTaskModel()
        #expect(draft.appendTorrentFiles([file]))
        #expect(draft.linkCount == 1)
        #expect(draft.links.first?.link.kind == .http)
        #expect(draft.links.first?.metadataError == nil)
        #expect(draft.parsedLinks.first?.original == file.absoluteString)
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        let router = OpenURLRouter(model: model, settings: SettingsModel())
        #expect(router.open([file]))
        #expect(model.tasks.isEmpty)
        #expect(model.isShowingNewTask)
        #expect(!OpenURLRequest.isRemote(try #require(request.links.first)))
    }

    @Test func proxySessionRecoveryKeepsPauseReasonsAndUsesTheExistingConcurrencyLimit() async throws {
        let link = try #require(LinkParser.parse("https://example.org/file.bin").first)
        let storage = try TemporaryDefaults(prefix: "proxy-recovery-intent.")
        defer { storage.clean() }
        storage.defaults.set(["http:restored-8": "user"], forKey: "downloadScheduling.pauseReasons")
        var tasks = (0..<9).map { index in
            var task = DownloadTask(link: link, autoExtract: false)
            task.engineTaskID = "restored-\(index)"
            task.status = .downloading
            return task
        }
        tasks[1].status = .paused
        for (offset, reason) in [DownloadTask.PauseReason.diskSpace, .volumeUnavailable, .systemSleep, .schedule].enumerated() {
            tasks[offset + 2].pauseReason = reason
        }
        tasks[7].status = .queued
        let model = AppModel(tasks: tasks, preventsSleepWhileDownloading: false)
        model.automaticPauseStore = QueuePauseStore(defaults: nil)
        model.automaticPauseStore.setManuallyPaused(true, for: tasks[6])
        let engine = FakeEngine()
        let coordinator = DownloadCoordinator(model: model, engines: [engine], schedulingDefaults: storage.defaults)
        coordinator.queueProxyRestoredTasks(Set(tasks.compactMap(\.engineTaskID)))
        #expect(model.tasks[0].status == .queued)
        #expect(model.tasks[7].status == .queued)
        #expect(model.tasks[1...6].allSatisfy { $0.status == .paused })
        #expect(model.tasks[8].status == .paused)
        #expect(model.tasks[2...5].compactMap(\.pauseReason) == [.diskSpace, .volumeUnavailable, .systemSleep, .schedule])
        await coordinator.start(options: .init(downloadDirectory: FileManager.default.temporaryDirectory, maxConcurrentDownloads: 1))
        #expect(await engine.resumedIDs == ["restored-0"])
        #expect(model.automaticPauseStore.isManuallyPaused(model.tasks[6]))
        await coordinator.stop()
    }

    @Test func proxySessionRecoveryHonorsAClosedTransferSchedule() async throws {
        let storage = try TemporaryDefaults(prefix: "proxy-recovery-schedule.")
        defer { storage.clean() }
        let settings = SettingsModel(defaults: storage.defaults)
        settings.transferScheduleEnabled = true
        settings.transferScheduleStartTime = "09:00"
        settings.transferScheduleEndTime = "10:00"
        let today = Calendar.current.component(.weekday, from: .now)
        settings.transferScheduleWeekdays = [(today + 1) % 7 + 1]
        let link = try #require(LinkParser.parse("https://example.org/file.bin").first)
        var task = DownloadTask(link: link, autoExtract: false)
        task.engineTaskID = "scheduled-restore"
        task.status = .downloading
        let model = AppModel(tasks: [task], preventsSleepWhileDownloading: false)
        model.downloadSettings = settings
        model.automaticPauseStore = QueuePauseStore(defaults: nil)
        let engine = FakeEngine()
        let coordinator = DownloadCoordinator(model: model, engines: [engine])
        coordinator.queueProxyRestoredTasks(["scheduled-restore"])
        #expect(model.tasks[0].status == .paused)
        #expect(model.tasks[0].pauseReason == .schedule)
        #expect(model.automaticPauseReasons(for: model.tasks[0]).contains(.schedule))
        await coordinator.start(options: .init(downloadDirectory: FileManager.default.temporaryDirectory))
        #expect(await engine.resumedIDs.isEmpty)
        await coordinator.stop()
    }

    @Test func authenticationFlagIsOptionalForOldTaskHistory() throws {
        let link = try #require(LinkParser.parse("https://example.org/example.bin").first)
        var task = DownloadTask(link: link, autoExtract: false)
        #expect(task.hasHTTPCredentials == nil)
        task.hasHTTPCredentials = true
        let decoded = try JSONDecoder().decode(DownloadTask.self, from: JSONEncoder().encode(task))
        #expect(decoded.hasHTTPCredentials == true)
    }

    @Test func onlyActiveHTTPVideosCanStartBuffering() throws {
        let link = try #require(LinkParser.parse("https://example.org/example.mp4").first)
        var task = DownloadTask(link: link, autoExtract: false)
        task.engineTaskID = "example"
        task.status = .downloading
        task.savePath = URL(filePath: "/tmp/.mulee-incomplete/example/example.mp4")
        #expect(StreamingPlayback.canPlay(task))
        task.status = .failed
        #expect(!StreamingPlayback.canPlay(task))
        task.status = .downloading
        task.fileMissing = true
        #expect(!StreamingPlayback.canPlay(task))
        task.fileMissing = false
        task.savePath = URL(filePath: "/tmp/.mulee-incomplete/example/example.zip")
        #expect(!StreamingPlayback.canPlay(task))
    }
}
