import Foundation
import MuleeCore
import Testing
@testable import Mulee

@Suite @MainActor struct DownloadCoordinatorTests {
    private let options = EngineOptions(downloadDirectory: URL(filePath: "/tmp/Mulee"))

    @Test func httpUsesEngineAndOtherKindsRemainUnavailable() async throws {
        let model = AppModel(tasks: [])
        let engine = FakeEngine()
        let coordinator = DownloadCoordinator(model: model, engines: [engine])
        await coordinator.start(options: options)
        let directory = URL(filePath: "/tmp/chosen")
        let links = NewTaskPreviewData.links

        await coordinator.add(links: links, autoExtract: true, directory: directory)

        #expect(await engine.addedLinks == links.filter { $0.kind == .http })
        #expect(await engine.directories == [directory])
        #expect(model.tasks.count == links.count)
        let http = try #require(model.tasks.first { $0.kind == .http })
        #expect(http.status == .queued)
        #expect(http.engineTaskID == "task-1")
        #expect(http.postDownload.autoExtract)
        #expect(model.tasks.filter { $0.kind != .http }.allSatisfy { $0.status == .engineUnavailable && $0.engineTaskID == nil })
        await coordinator.stop()
    }

    @Test func addFailureCreatesFailedTaskWithReason() async throws {
        let model = AppModel(tasks: [])
        let engine = FakeEngine()
        let coordinator = DownloadCoordinator(model: model, engines: [engine])
        await coordinator.start(options: options)
        await engine.failOperations(with: .rpc(code: 2, message: "无法创建文件"))

        await coordinator.add(links: LinkParser.parse("https://example.com/file.zip"), autoExtract: false)

        let task = try #require(model.tasks.first)
        #expect(task.status == .failed)
        #expect(task.engineTaskID == nil)
        #expect(task.errorMessage == "无法创建文件（2）")
        await coordinator.stop()
    }

    @Test func actionsRouteToEngineAndRemoveKeepsFiles() async throws {
        let model = AppModel(tasks: [])
        let engine = FakeEngine()
        let coordinator = DownloadCoordinator(model: model, engines: [engine])
        await coordinator.start(options: options)
        await coordinator.add(links: LinkParser.parse("https://example.com/file.zip"), autoExtract: false)
        let id = try #require(model.tasks.first?.id)

        await coordinator.pause(id)
        #expect(model.tasks.first?.status == .paused)
        await coordinator.resume(id)
        #expect(model.tasks.first?.status == .queued)
        await coordinator.remove(id)

        #expect(await engine.pausedIDs == ["task-1"])
        #expect(await engine.resumedIDs == ["task-1"])
        #expect(await engine.removedIDs == ["task-1"])
        #expect(await engine.deletesFiles == [false])
        #expect(model.tasks.isEmpty)
        #expect(model.selectedTaskID == nil)
        await coordinator.stop()
    }

    @Test func actionFailureIsVisibleAndPreservesTask() async throws {
        let model = AppModel(tasks: [])
        let engine = FakeEngine()
        let coordinator = DownloadCoordinator(model: model, engines: [engine])
        await coordinator.start(options: options)
        await coordinator.add(links: LinkParser.parse("https://example.com/file.zip"), autoExtract: false)
        let id = try #require(model.tasks.first?.id)
        await engine.failOperations(with: .notRunning)

        await coordinator.pause(id)
        await coordinator.resume(id)
        await coordinator.remove(id)

        #expect(model.tasks.count == 1)
        #expect(model.tasks.first?.errorMessage == "下载引擎未运行")
        #expect(await engine.removedIDs.isEmpty)
        await coordinator.stop()
    }

    @Test func tasksWithoutEngineIDUseLocalActions() async throws {
        let model = AppModel(tasks: [MockData.longTailTask])
        let engine = FakeEngine()
        let coordinator = DownloadCoordinator(model: model, engines: [engine])
        let id = try #require(model.tasks.first?.id)

        await coordinator.pause(id)
        #expect(model.tasks.first?.status == .paused)
        await coordinator.resume(id)
        #expect(model.tasks.first?.status == .waitingForSources)
        await coordinator.remove(id)

        #expect(model.tasks.isEmpty)
        #expect(await engine.pausedIDs.isEmpty)
        #expect(await engine.resumedIDs.isEmpty)
        #expect(await engine.removedIDs.isEmpty)
    }

    @Test func startupFailureDoesNotPreventOtherEngineStarting() async {
        let model = AppModel(tasks: [])
        let failing = FakeEngine(startError: .binaryNotFound)
        let working = FakeEngine(kind: .bittorrent)
        let coordinator = DownloadCoordinator(model: model, engines: [failing, working])

        await coordinator.start(options: options)

        #expect(model.engineStates[.http] == .failed("未找到 aria2"))
        #expect(model.engineStates[.bittorrent] == .running)
        #expect(model.engineStates[.ed2k] == .unavailable)
        #expect(await working.isRunning)
        #expect(EngineStatusPresentation.title(for: model.engineStates[.http] ?? .unavailable) == "未找到 aria2")
        await coordinator.stop()
        #expect(await failing.stopCount == 1)
        #expect(await working.stopCount == 1)
    }

    @Test func pollingMergesAndCapsRateHistoryWithoutDeletingOnFailure() async throws {
        let model = AppModel(tasks: [])
        let engine = FakeEngine()
        let coordinator = DownloadCoordinator(model: model, engines: [engine])
        await coordinator.start(options: options)
        let snapshot = EngineTaskSnapshot(
            engineTaskID: "restored", name: "restored.zip", totalBytes: 100,
            receivedBytes: 20, downloadRate: 10, uploadRate: 0, status: .downloading,
            connections: 2, savePath: nil, sourceURL: nil, errorMessage: nil
        )
        await engine.setSnapshots([snapshot])
        model.downloadRateHistory = []

        for _ in 0..<35 {
            await coordinator.poll()
        }

        #expect(model.tasks.first?.engineTaskID == "restored")
        #expect(model.downloadRateHistory == Array(repeating: 10, count: 30))
        await engine.failSnapshots(with: .notRunning)
        await coordinator.poll()
        #expect(model.tasks.count == 1)
        #expect(model.engineStates[.http] == .failed("下载引擎未运行"))
        await coordinator.stop()
        let history = model.downloadRateHistory
        await coordinator.poll()
        #expect(model.downloadRateHistory == history)
    }

    @Test func applyDebouncesAndReportsErrors() async throws {
        let model = AppModel(tasks: [])
        let engine = FakeEngine()
        let coordinator = DownloadCoordinator(model: model, engines: [engine])
        await coordinator.start(options: options)
        var changed = options
        changed.downloadLimit = 5_000_000

        coordinator.apply(options: options)
        coordinator.apply(options: changed)
        try await Task.sleep(for: .milliseconds(650))

        #expect(await engine.appliedOptions == [changed])
        await engine.failApply(with: .notRunning)
        coordinator.apply(options: options)
        try await Task.sleep(for: .milliseconds(650))
        #expect(model.engineStates[.http] == .failed("下载引擎未运行"))
        await coordinator.stop()
    }

    @Test func staleSnapshotCannotRemoveTaskAddedWhilePolling() async {
        let model = AppModel(tasks: [])
        let engine = FakeEngine()
        let coordinator = DownloadCoordinator(model: model, engines: [engine])
        await coordinator.start(options: options)
        await engine.holdNextSnapshot()
        let polling = Task { await coordinator.poll() }
        await engine.waitForHeldSnapshot()

        await coordinator.add(links: LinkParser.parse("https://example.com/new.zip"), autoExtract: false)
        await engine.releaseSnapshot()
        await polling.value

        #expect(model.tasks.count == 1)
        #expect(model.tasks.first?.engineTaskID == "task-1")
        await coordinator.stop()
    }

    @Test func cancelledStartupDoesNotStartEngines() async {
        let model = AppModel(tasks: [])
        let engine = FakeEngine()
        let coordinator = DownloadCoordinator(model: model, engines: [engine])
        let startup = Task {
            await coordinator.start(options: options)
        }
        startup.cancel()

        await startup.value

        #expect(await engine.isRunning == false)
        #expect(model.engineStates[.http] == .unavailable)
        await coordinator.stop()
    }
}
