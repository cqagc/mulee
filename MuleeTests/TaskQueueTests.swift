import Foundation
import MuleeCore
import Testing
@testable import Mulee

@Suite @MainActor struct TaskQueueTests {
    private func task(_ name: String, status: TaskStatus = .queued) -> DownloadTask {
        DownloadTask(
            name: name, fileExtension: "bin", kind: .http, status: status,
            totalBytes: 100, receivedBytes: 0, detail: .http(connections: 1),
            postDownload: PostDownloadInfo(autoExtract: false), sourceLink: "https://example.org/file.bin",
            engineTaskID: name
        )
    }

    @Test func priorityThenQueuePositionControlsAdmission() {
        var low = task("low")
        low.priority = .low
        low.queuePosition = -10
        var highLast = task("high-last")
        highLast.priority = .high
        highLast.queuePosition = 10
        var highFirst = task("high-first")
        highFirst.priority = .high
        highFirst.queuePosition = 1
        let normal = task("normal")
        let tasks = [low, highLast, normal, highFirst]
        #expect(GlobalConcurrencyPolicy.admitted(tasks: tasks, limit: 1) == [highFirst.id])
        #expect(GlobalConcurrencyPolicy.admitted(tasks: tasks, limit: 2) == [highFirst.id, highLast.id])
        #expect(GlobalConcurrencyPolicy.admitted(tasks: tasks, limit: 3) == [highFirst.id, highLast.id, normal.id])
    }

    @Test func priorityAndQueueMovesNeverPreemptRunningTasks() throws {
        let running = task("running", status: .downloading)
        var queued = task("queued")
        queued.priority = .high
        let moved = GlobalConcurrencyPolicy.moving(tasks: [running, queued], id: queued.id, toFront: true)
        #expect(moved[0].id == running.id)
        #expect(moved[1].queuePosition == 0)
        #expect(GlobalConcurrencyPolicy.admitted(tasks: moved, limit: 1) == [running.id])
        let last = GlobalConcurrencyPolicy.moving(tasks: moved, id: queued.id, toFront: false)
        #expect(last[1].queuePosition == 1)
        let restored = try JSONDecoder().decode([DownloadTask].self, from: JSONEncoder().encode(last))
        #expect(restored[1].queuePosition == 1)
        #expect(restored[1].priority == .high)
        #expect(GlobalConcurrencyPolicy.moving(tasks: moved, id: UUID(), toFront: true) == moved)
    }

    @Test func loweringLimitQueuesOverflowButKeepsRecoveredTask() {
        let first = task("first", status: .downloading)
        let second = task("second", status: .downloading)
        let recovered = task("recovered", status: .downloading)
        let queued = task("queued")
        let tasks = [first, second, recovered, queued]
        #expect(GlobalConcurrencyPolicy.admitted(tasks: tasks, limit: 1) == [first.id])
        #expect(GlobalConcurrencyPolicy.admitted(tasks: tasks, limit: 1, recovered: [recovered.id]) == [first.id, recovered.id])
        #expect(GlobalConcurrencyPolicy.admitted(tasks: tasks, limit: 0) == [first.id])
    }

    @Test func stalledBoundaryDisabledClockAndExemptStatuses() {
        var stalled = task("stalled", status: .downloading)
        let now = Date(timeIntervalSince1970: 1_000)
        let last = now.addingTimeInterval(-600)
        #expect(GlobalConcurrencyPolicy.isStalled(stalled, lastActivity: last, now: now, minutes: 10))
        #expect(!GlobalConcurrencyPolicy.isStalled(stalled, lastActivity: last, now: now.addingTimeInterval(-1), minutes: 10))
        #expect(!GlobalConcurrencyPolicy.isStalled(stalled, lastActivity: last, now: now, minutes: 0))
        #expect(!GlobalConcurrencyPolicy.isStalled(stalled, lastActivity: nil, now: now, minutes: 10))
        #expect(!GlobalConcurrencyPolicy.isStalled(stalled, lastActivity: now, now: last, minutes: 10))
        stalled.downloadRate = 1
        #expect(!GlobalConcurrencyPolicy.isStalled(stalled, lastActivity: last, now: now, minutes: 10))
        stalled.downloadRate = 0
        for status in [TaskStatus.seeding, .waitingForSources, .paused, .queued] {
            stalled.status = status
            #expect(!GlobalConcurrencyPolicy.isStalled(stalled, lastActivity: last, now: now, minutes: 10))
        }
    }

    @Test func stalledConnectionYieldsAndRecoveryDoesNotPauseEitherTask() async throws {
        let engine = FakeEngine()
        let first = task("first", status: .downloading)
        let next = task("next", status: .paused)
        let model = AppModel(tasks: [first, next], preventsSleepWhileDownloading: false)
        let scheduling = DownloadScheduling(defaults: nil)
        scheduling.queue(next)
        let options = EngineOptions(downloadDirectory: URL(filePath: "/tmp"), maxConcurrentDownloads: 1)
        let start = Date(timeIntervalSince1970: 1_000)
        await scheduling.refresh(model: model, engines: [engine], options: options, now: start, isCurrent: { true })
        #expect(await engine.resumedIDs.isEmpty)
        await scheduling.refresh(model: model, engines: [engine], options: options, now: start.addingTimeInterval(600), isCurrent: { true })
        #expect(model.stalledYieldTaskIDs == [first.id])
        #expect(await engine.resumedIDs == ["next"])
        #expect(await engine.appliedOptions.last?.maxConcurrentDownloads == 2)
        #expect(TaskPresentation(task: first, isYieldingSlot: true).statusTitle == String(localized: "卡住，已让出名额"))
        model.tasks[0].downloadRate = 100
        model.tasks[1].status = .downloading
        model.tasks[1].downloadRate = 100
        await scheduling.refresh(model: model, engines: [engine], options: options, now: start.addingTimeInterval(601), isCurrent: { true })
        #expect(model.stalledYieldTaskIDs.isEmpty)
        #expect(await engine.pausedIDs.isEmpty)
        #expect(model.tasks.allSatisfy { $0.status == .downloading })
        let third = task("third", status: .paused)
        model.tasks.append(third)
        scheduling.queue(third)
        await scheduling.refresh(model: model, engines: [engine], options: options, now: start.addingTimeInterval(602), isCurrent: { true })
        #expect(await engine.resumedIDs == ["next"])
    }

    @Test func taskQueueFieldsDecodeOldJSONAndRoundTrip() throws {
        var original = task("legacy")
        let encoded = try JSONEncoder().encode(original)
        var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in ["priority", "downloadLimit", "uploadLimit", "queuePosition", "createdAt"] { json.removeValue(forKey: key) }
        let legacy = try JSONDecoder().decode(DownloadTask.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(legacy.priority == .normal)
        #expect(legacy.downloadLimit == nil && legacy.uploadLimit == nil)
        #expect(legacy.queuePosition == nil && legacy.createdAt == nil)
        original.priority = .high
        original.downloadLimit = 123_000
        original.uploadLimit = 45_000
        original.queuePosition = -3
        let restored = try JSONDecoder().decode(DownloadTask.self, from: JSONEncoder().encode(original))
        #expect(restored == original)
        let saved = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        #expect(saved["priority"] as? String == "high")
    }

    @Test func schedulerReleasesTasksInPriorityAndPositionOrder() async {
        let engine = FakeEngine()
        var normal = task("normal", status: .paused)
        normal.queuePosition = 0
        var highLast = task("high-last", status: .paused)
        highLast.priority = .high
        highLast.queuePosition = 2
        var highFirst = task("high-first", status: .paused)
        highFirst.priority = .high
        highFirst.queuePosition = 1
        let model = AppModel(tasks: [normal, highLast, highFirst], preventsSleepWhileDownloading: false)
        let scheduler = DownloadScheduling(defaults: nil)
        for task in model.tasks { scheduler.queue(task) }
        await scheduler.refresh(
            model: model, engines: [engine],
            options: EngineOptions(downloadDirectory: URL(filePath: "/tmp"), maxConcurrentDownloads: 2),
            isCurrent: { true }
        )
        #expect(await engine.resumedIDs == ["high-first", "high-last"])
        #expect(scheduler.isQueuePaused(normal))
    }

    @Test func loweringConcurrencyImmediatelyQueuesOrdinaryOverflow() async {
        let engine = FakeEngine()
        var first = task("first", status: .downloading)
        first.downloadRate = 1
        var second = task("second", status: .downloading)
        second.downloadRate = 1
        let model = AppModel(tasks: [first, second], preventsSleepWhileDownloading: false)
        let scheduler = DownloadScheduling(defaults: nil)
        var options = EngineOptions(downloadDirectory: URL(filePath: "/tmp"), maxConcurrentDownloads: 2)
        let now = Date(timeIntervalSince1970: 1_000)
        await scheduler.refresh(model: model, engines: [engine], options: options, now: now, isCurrent: { true })
        #expect(await engine.pausedIDs.isEmpty)
        options.maxConcurrentDownloads = 1
        await scheduler.refresh(model: model, engines: [engine], options: options, now: now, isCurrent: { true })
        #expect(await engine.pausedIDs == ["second"])
        #expect(model.tasks[1].status == .queued)
        #expect(await engine.appliedOptions.last?.maxConcurrentDownloads == 1)
    }

    @Test func stalledSettingCanDisableAndChangeYieldThreshold() async throws {
        let storage = try TemporaryDefaults(prefix: "queue-yield.")
        defer { storage.clean() }
        let settings = SettingsModel(defaults: storage.defaults)
        settings.stalledYieldMinutes = 0
        let engine = FakeEngine()
        let stalled = task("stalled", status: .downloading)
        let model = AppModel(tasks: [stalled], preventsSleepWhileDownloading: false)
        model.downloadSettings = settings
        let scheduler = DownloadScheduling(defaults: nil)
        let options = EngineOptions(downloadDirectory: URL(filePath: "/tmp"))
        let now = Date(timeIntervalSince1970: 1_000)
        await scheduler.refresh(model: model, engines: [engine], options: options, now: now, isCurrent: { true })
        await scheduler.refresh(model: model, engines: [engine], options: options, now: now.addingTimeInterval(600), isCurrent: { true })
        #expect(model.stalledYieldTaskIDs.isEmpty)
        settings.stalledYieldMinutes = 1
        await scheduler.refresh(model: model, engines: [engine], options: options, now: now.addingTimeInterval(600), isCurrent: { true })
        #expect(model.stalledYieldTaskIDs == [stalled.id])
        model.tasks[0].status = .waitingForSources
        await scheduler.refresh(model: model, engines: [engine], options: options, now: now.addingTimeInterval(601), isCurrent: { true })
        #expect(model.stalledYieldTaskIDs.isEmpty)
    }
}
