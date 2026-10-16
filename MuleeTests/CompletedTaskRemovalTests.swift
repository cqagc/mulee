import Foundation
import MuleeCore
import Testing
@testable import Mulee

@Suite @MainActor struct CompletedTaskRemovalTests {
    @Test(arguments: [false, true])
    func appRemovalCallsEngineAndPreservesFiles(clearAll: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "CompletedRemoval-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "视频.mp4")
        let contents = Data("已下载视频".utf8)
        try contents.write(to: file)
        let completed = task(id: "removed", file: file)
        let active = task(id: "active", file: file, status: .downloading)
        let store = TaskHistoryStore(directory: root)
        try store.flush(tasks: [completed, active])
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        model.loadTaskHistory(from: store)
        let video = FakeEngine(kind: .video)
        await video.setSnapshots([snapshot(id: "removed", file: file)])
        let coordinator = DownloadCoordinator(model: model, engines: [video])
        await coordinator.start(options: EngineOptions(downloadDirectory: root))
        await video.holdNextSnapshot()
        let polling = Task { await coordinator.poll() }
        await video.waitForHeldSnapshot()

        if clearAll { model.clearCompletedTasks() }
        else { model.remove(completed.id) }

        #expect(model.activeTasks.map(\.id) == [active.id])
        #expect(model.tasks.first { $0.id == completed.id }?.deletedAt != nil)
        #expect(model.selectedTaskID == nil)
        await video.releaseSnapshot()
        await polling.value
        try await waitUntil { await video.removedIDs == ["removed"] }
        #expect(await video.deletesFiles == [false])
        await coordinator.poll()
        #expect(model.activeTasks.contains { $0.engineTaskID == "removed" } == false)
        #expect(try Data(contentsOf: file) == contents)
        model.flushTaskHistory()
        await coordinator.stop()
        let saved = TaskHistoryStore(directory: root).load().tasks
        #expect(saved.filter { $0.deletedAt == nil }.map(\.id) == [active.id])
        #expect(saved.first { $0.id == completed.id }?.deletedAt != nil)
    }

    @Test(arguments: [false, true])
    func offlineOrFailedRemovalPersistsAcrossRestart(offline: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "CompletedRemoval-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "视频.mp4")
        let completed = task(id: "removed", file: file)
        let store = TaskHistoryStore(directory: root)
        try store.flush(tasks: [completed])
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        model.loadTaskHistory(from: store)
        let video = FakeEngine(kind: .video)
        let coordinator = DownloadCoordinator(model: model, engines: [video])
        let options = EngineOptions(downloadDirectory: root)
        if !offline {
            await coordinator.start(options: options)
            await video.failOperations(with: .notRunning)
        }

        await coordinator.remove(completed.id)

        #expect(model.activeTasks.isEmpty)
        await coordinator.stop()
        // 不 flush tasks.json：模拟保存列表前退出，删除意图仍须优先于旧历史。
        let restored = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        restored.loadTaskHistory(from: TaskHistoryStore(directory: root))
        #expect(restored.activeTasks.isEmpty)
        #expect(restored.tasks.first?.deletedAt != nil)
        let nextVideo = FakeEngine(kind: .video)
        await nextVideo.setSnapshots([snapshot(id: "removed", file: file), snapshot(id: "duplicate", file: file)])
        // 补删再次失败时也必须过滤；同 URL 的另一条任务照常恢复。
        await nextVideo.failOperations(with: .notRunning)
        let next = DownloadCoordinator(model: restored, engines: [nextVideo])
        await next.start(options: options)
        await next.poll()
        #expect(restored.activeTasks.map(\.engineTaskID) == ["duplicate"])
        await next.stop()
        restored.flushTaskHistory()

        let recovered = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        recovered.loadTaskHistory(from: TaskHistoryStore(directory: root))
        let workingVideo = FakeEngine(kind: .video)
        let working = DownloadCoordinator(model: recovered, engines: [workingVideo])
        await working.start(options: options)
        #expect(await workingVideo.removedIDs == ["removed"])
        #expect(await workingVideo.deletesFiles == [false])
        await working.stop()
        model.flushTaskHistory()
    }

    @Test func deletionWhileVideoPreparesIsRetriedAfterStartup() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "CompletedRemoval-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "视频.mp4")
        let completed = task(id: "removed", file: file)
        let store = TaskHistoryStore(directory: root)
        try store.flush(tasks: [completed])
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        model.loadTaskHistory(from: store)
        let video = FakeEngine(kind: .video)
        let gate = VideoEnginePreparationGate()
        let coordinator = DownloadCoordinator(model: model, engines: [], videoEngineFactory: { _ in
            await gate.wait()
            return video
        })
        await coordinator.start(options: EngineOptions(downloadDirectory: root))

        model.clearCompletedTasks()
        #expect(model.activeTasks.isEmpty)
        #expect(model.tasks.first?.deletedAt != nil)
        gate.release()
        try await waitUntil { model.engineStates[.video] == .running }

        #expect(await video.removedIDs == ["removed"])
        #expect(await video.deletesFiles == [false])
        await coordinator.stop()
        model.flushTaskHistory()
    }

    private func task(id: String, file: URL, status: TaskStatus = .completed) -> DownloadTask {
        DownloadTask(
            name: "视频.mp4", fileExtension: "mp4", kind: .video, status: status,
            totalBytes: 100, receivedBytes: status == .completed ? 100 : 20,
            detail: .video(site: .other, quality: "兼容优先", danmakuToASS: false),
            postDownload: PostDownloadInfo(autoExtract: false),
            sourceLink: "https://example.invalid/fixture", engineTaskID: id, savePath: file
        )
    }

    private func snapshot(id: String, file: URL) -> EngineTaskSnapshot {
        EngineTaskSnapshot(
            engineTaskID: id, name: "视频.mp4", totalBytes: 100, receivedBytes: 100,
            downloadRate: 0, uploadRate: 0, status: .completed, connections: 0,
            savePath: file, sourceURL: URL(string: "https://example.invalid/fixture"), errorMessage: nil
        )
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()), ContinuousClock.now < deadline { await Task.yield() }
        try #require(await condition())
    }
}
