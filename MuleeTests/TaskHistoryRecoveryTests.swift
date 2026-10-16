import Foundation
import MuleeCore
import Testing
@testable import Mulee

@Suite @MainActor struct TaskHistoryRecoveryTests {
    private let options = EngineOptions(downloadDirectory: URL(filePath: "/tmp/Mulee"))

    private func task(status: TaskStatus, id: String = "gid") -> DownloadTask {
        DownloadTask(
            name: "资料.zip", fileExtension: "zip", kind: .http, status: status,
            totalBytes: 100, receivedBytes: status == .completed ? 100 : 20,
            detail: .http(connections: 0), postDownload: PostDownloadInfo(autoExtract: true),
            sourceLink: "https://example.com/archive.zip", engineTaskID: id,
            savePath: URL(filePath: "/tmp/下载/资料.zip"),
            errorMessage: status == .failed ? "原来的错误" : nil
        )
    }

    private func snapshot(id: String = "gid", status: TaskStatus = .downloading) -> EngineTaskSnapshot {
        EngineTaskSnapshot(
            engineTaskID: id, name: "资料.zip", totalBytes: 100,
            receivedBytes: status == .completed ? 100 : 40, downloadRate: 10, uploadRate: 0,
            status: status, connections: 2, savePath: URL(filePath: "/tmp/下载/资料.zip"),
            sourceURL: URL(string: "https://example.com/archive.zip"), errorMessage: nil
        )
    }

    @Test(arguments: [TaskStatus.completed, .failed, .engineUnavailable])
    func missingTerminalHistoryIsUnchanged(_ status: TaskStatus) {
        let original = task(status: status)

        let result = EngineSnapshotMerger.merge(tasks: [original], snapshots: [.http: []], now: .now)

        #expect(result == [original])
    }

    @Test(arguments: [TaskStatus.downloading, .queued, .paused])
    func missingUnfinishedHistoryBecomesFailed(_ status: TaskStatus) throws {
        var original = task(status: status)
        original.downloadRate = 10
        original.uploadRate = 2
        original.estimatedTimeRemaining = .seconds(8)

        let result = EngineSnapshotMerger.merge(tasks: [original], snapshots: [.http: []], now: .now)

        let failed = try #require(result.first)
        #expect(result.count == 1)
        #expect(failed.id == original.id)
        #expect(failed.engineTaskID == original.engineTaskID)
        #expect(failed.status == .failed)
        #expect(failed.errorMessage == "上次退出前的进度没能恢复，可以重新下载")
        #expect(failed.downloadRate == 0)
        #expect(failed.uploadRate == 0)
        #expect(failed.estimatedTimeRemaining == nil)
    }

    @Test func engineNotStartedOrSnapshotNotAvailableDoesNotMerge() async {
        let original = task(status: .paused)
        let model = AppModel(tasks: [original], preventsSleepWhileDownloading: false)
        let engine = FakeEngine(startError: .binaryNotFound)
        let coordinator = DownloadCoordinator(model: model, engines: [engine])

        #expect(EngineSnapshotMerger.merge(tasks: [original], snapshots: [:], now: .now) == [original])
        await coordinator.poll()
        #expect(model.tasks == [original])
        await coordinator.start(options: options)
        await coordinator.poll()

        #expect(model.tasks == [original])
        #expect(model.engineStates[.http] == .failed("未找到 aria2"))
        await coordinator.stop()
    }

    @Test func restoredEngineSessionMatchesHistoryIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "TaskHistory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var completed = task(status: .completed, id: "completed")
        completed.savePath = directory.appendingPathComponent("missing.zip")
        let tasks = [completed, task(status: .paused)]
        try TaskHistoryStore(directory: directory).flush(tasks: tasks)
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        model.loadTaskHistory(from: TaskHistoryStore(directory: directory))
        let engine = FakeEngine()
        await engine.setSnapshots([snapshot()])
        let coordinator = DownloadCoordinator(model: model, engines: [engine])

        await coordinator.start(options: options)
        await coordinator.poll()
        model.flushTaskHistory()

        #expect(model.tasks.count == 2)
        var expectedCompleted = try #require(TaskHistoryStore.durableTasks(tasks).first)
        expectedCompleted.fileMissing = true
        #expect(model.tasks.first == expectedCompleted)
        #expect(model.tasks.last?.id == tasks.last?.id)
        #expect(model.tasks.last?.receivedBytes == 40)
        #expect(model.tasks.last?.status == .downloading)
        #expect(model.tasks.last?.postDownload.autoExtract == true)
        #expect(TaskHistoryStore(directory: directory).load().tasks.last?.receivedBytes == 0)
        await coordinator.stop()
    }

    @Test func clearCompletedOnlyRemovesCompletedRecordsAndKeepsFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "TaskHistory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let downloadedFile = directory.appending(path: "资料.zip")
        let contents = Data("已下载的文件".utf8)
        try contents.write(to: downloadedFile)
        var completed = task(status: .completed, id: "completed")
        completed.savePath = downloadedFile
        let others: [DownloadTask] = [
            task(status: .failed, id: "failed"),
            task(status: .engineUnavailable, id: "unavailable"),
            task(status: .downloading, id: "active"),
            task(status: .paused, id: "paused"),
            task(status: .queued, id: "queued")
        ]
        let store = TaskHistoryStore(directory: directory)
        try store.flush(tasks: [completed] + others)
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        model.loadTaskHistory(from: store)
        model.selectedTaskID = completed.id
        let before = model.tasks.filter { $0.status != .completed }
        let engine = FakeEngine()
        await engine.setSnapshots([snapshot(id: "completed", status: .completed)])
        let coordinator = DownloadCoordinator(model: model, engines: [engine])
        await coordinator.start(options: options)
        #expect(model.hasCompletedTasks)

        model.clearCompletedTasks()
        model.flushTaskHistory()

        #expect(model.activeTasks == before)
        #expect(model.tasks.first { $0.id == completed.id }?.deletedAt != nil)
        #expect(model.selectedTaskID == nil)
        #expect(!model.hasCompletedTasks)
        #expect(TaskHistoryStore(directory: directory).load().tasks.filter { $0.deletedAt == nil } == before)
        #expect(try Data(contentsOf: downloadedFile) == contents)
        #expect(await engine.removedIDs.isEmpty)
        await coordinator.poll()
        #expect(model.activeTasks.contains { $0.id == completed.id || $0.engineTaskID == "completed" } == false)
        await coordinator.stop()
        model.flushTaskHistory()
    }

    @Test func deletingCompletedRecordDoesNotContactEngineOrReimportSnapshot() async {
        let completed = task(status: .completed)
        let model = AppModel(tasks: [completed], preventsSleepWhileDownloading: false)
        let engine = FakeEngine()
        await engine.setSnapshots([snapshot(status: .completed)])
        let coordinator = DownloadCoordinator(model: model, engines: [engine])
        await coordinator.start(options: options)
        await engine.holdNextSnapshot()
        let polling = Task { await coordinator.poll() }
        await engine.waitForHeldSnapshot()

        model.remove(completed.id)
        #expect(model.activeTasks.isEmpty)
        #expect(model.tasks.first?.deletedAt != nil)
        await engine.releaseSnapshot()
        await polling.value
        await coordinator.poll()

        #expect(model.activeTasks.isEmpty)
        #expect(model.tasks.first?.deletedAt != nil)
        #expect(await engine.removedIDs.isEmpty)
        #expect(await engine.deletesFiles.isEmpty)
        await coordinator.stop()
    }

    @Test func deletingActiveRecordCannotBeReintroducedByStaleSnapshot() async {
        let active = task(status: .downloading)
        let model = AppModel(tasks: [active], preventsSleepWhileDownloading: false)
        let engine = FakeEngine()
        await engine.setSnapshots([snapshot()])
        let coordinator = DownloadCoordinator(model: model, engines: [engine])
        await coordinator.start(options: options)
        await engine.holdNextSnapshot()
        let polling = Task { await coordinator.poll() }
        await engine.waitForHeldSnapshot()

        await coordinator.remove(active.id)
        await engine.releaseSnapshot()
        await polling.value
        await coordinator.poll()

        #expect(model.activeTasks.isEmpty)
        #expect(model.tasks.first?.deletedAt != nil)
        #expect(await engine.removedIDs == ["gid"])
        #expect(await engine.deletesFiles == [false])
        await coordinator.stop()
    }

    @Test func clearingWithoutCompletedTasksPreservesSelection() {
        let failed = task(status: .failed)
        let model = AppModel(tasks: [failed], preventsSleepWhileDownloading: false)
        model.selectedTaskID = failed.id

        model.clearCompletedTasks()

        #expect(model.tasks == [failed])
        #expect(model.selectedTaskID == failed.id)
        #expect(!model.hasCompletedTasks)
    }
}
