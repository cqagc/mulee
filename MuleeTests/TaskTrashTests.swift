import Foundation
import MuleeCore
import Testing
@testable import Mulee

@Suite @MainActor struct TaskTrashTests {
    @Test func deletionRestoreAndExpirationKeepFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("file.zip")
        try Data([1]).write(to: file)
        var task = MockData.longTailTask
        task.savePath = file
        task.status = .completed
        let model = AppModel(tasks: [task], preventsSleepWhileDownloading: false)
        let now = Date(timeIntervalSince1970: 100_000)
        model.trashRecord(task.id, now: now)
        #expect(model.activeTasks.isEmpty)
        #expect(model.tasks.count == 1)
        #expect(!model.hasCompletedTasks)
        #expect(!TaskTrash.isExpired(model.tasks[0], now: now.addingTimeInterval(TaskTrash.retention - 1)))
        #expect(TaskTrash.isExpired(model.tasks[0], now: now.addingTimeInterval(TaskTrash.retention)))
        model.restoreRecord(task.id)
        #expect(model.activeTasks.count == 1)
        #expect(model.tasks[0].status == .completed)
        model.trashRecord(task.id, now: now)
        model.purgeExpiredTrash(now: now.addingTimeInterval(TaskTrash.retention))
        #expect(model.tasks.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func trashedTasksDoNotCountAsTransfersOrRates() {
        var task = MockData.longTailTask
        task.status = .downloading
        task.downloadRate = 100
        task.uploadRate = 10
        let model = AppModel(tasks: [task], preventsSleepWhileDownloading: false)
        model.trashRecord(task.id)
        #expect(!model.hasActiveTransfers)
        #expect(model.totalDownloadRate == 0)
        #expect(model.totalUploadRate == 0)
        model.restoreRecord(task.id)
        #expect(model.tasks[0].status == .paused)
    }

    @Test func trashIsExcludedFromProtectionNotificationsActionsAndMenuBar() async throws {
        let defaults = try TemporaryDefaults(prefix: "TaskTrash-")
        defer { defaults.clean() }
        let settings = SettingsModel(defaults: defaults.defaults)
        var task = MockData.longTailTask
        task.status = .downloading
        task.deletedAt = .now
        let model = AppModel(tasks: [task], preventsSleepWhileDownloading: false)
        let center = DownloadNotificationCenterSpy()
        var now = Date(timeIntervalSince1970: 0)
        let notifications = NotificationService(model: model, settings: settings, center: center, now: { now })
        let controller = WhenAllDoneController(model: model, settings: settings, showsPanel: false) { _ in
            Issue.record("回收站任务不能触发下完后动作")
        }
        controller.select(.quit)
        let monitor = DiskReserveMonitor(model: model, settings: settings, volume: { $0 }) { _ in
            Issue.record("回收站任务不能参与磁盘保护")
            return 0
        }
        await monitor.refresh()
        model.tasks[0].status = .completed
        now += 10
        notifications.flushCompletionsIfDue()
        await notifications.waitForDelivery()
        #expect(center.requests.isEmpty)
        #expect(model.whenAllDoneSecondsRemaining == nil)
        #expect(model.diskReserveWarnings.isEmpty)
        #expect(MenuBarPresentation(tasks: model.tasks).isEmpty)
    }

    @Test func pendingCompletionIsSuppressedAfterTrashing() async throws {
        let defaults = try TemporaryDefaults(prefix: "TaskTrashPending-")
        defer { defaults.clean() }
        let settings = SettingsModel(defaults: defaults.defaults)
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        let center = DownloadNotificationCenterSpy()
        var now = Date(timeIntervalSince1970: 0)
        let notifications = NotificationService(model: model, settings: settings, center: center, now: { now })
        var task = MockData.longTailTask
        task.status = .completed
        model.tasks = [task]
        model.trashRecord(task.id)
        now += 10
        notifications.flushCompletionsIfDue()
        await notifications.waitForDelivery()
        #expect(center.requests.isEmpty)
        model.removeRecord(task.id)
        #expect(model.tasks.isEmpty)
    }

    @Test func restoredHTTPCompletionKeepsIdentityWhenSessionReturns() {
        var task = MockData.longTailTask
        task.kind = .http
        task.status = .completed
        task.engineTaskID = "completed-file"
        let model = AppModel(tasks: [task], preventsSleepWhileDownloading: false)
        model.trashRecord(task.id)
        model.restoreRecord(task.id)
        let snapshot = EngineTaskSnapshot(
            engineTaskID: "completed-file", name: "file.zip", totalBytes: 100, receivedBytes: 100,
            downloadRate: 0, uploadRate: 0, status: .completed, connections: 0,
            savePath: nil, sourceURL: nil, errorMessage: nil
        )
        let merged = EngineSnapshotMerger.merge(tasks: model.tasks, snapshots: [.http: [snapshot]], now: .now)
        #expect(merged.count == 1)
        #expect(merged.first?.id == task.id)
    }
}
