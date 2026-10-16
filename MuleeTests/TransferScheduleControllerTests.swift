import Foundation
import IOKit.pwr_mgt
import MuleeCore
import Testing
@testable import Mulee

@Suite @MainActor struct TransferScheduleControllerTests {
    private func calendar(_ zone: String = "UTC") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func date(_ text: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: text))
    }

    @Test func boundariesAndWeekdaysFollowTheStartDayAcrossMidnight() throws {
        let calendar = calendar()
        let schedule = TransferScheduleController.Configuration(startTime: "22:00", endTime: "07:00", weekdays: [6])
        #expect(!schedule.isActive(at: try date("2026-10-16T21:59:59Z"), calendar: calendar))
        #expect(schedule.isActive(at: try date("2026-10-16T22:00:00Z"), calendar: calendar))
        #expect(schedule.isActive(at: try date("2026-10-17T06:59:59Z"), calendar: calendar))
        #expect(!schedule.isActive(at: try date("2026-10-17T07:00:00Z"), calendar: calendar))
        #expect(!schedule.isActive(at: try date("2026-10-17T22:00:00Z"), calendar: calendar))
        #expect(schedule.nextStart(after: try date("2026-10-17T08:00:00Z"), calendar: calendar) == (try date("2026-10-23T22:00:00Z")))
        let daytime = TransferScheduleController.Configuration(startTime: "01:00", endTime: "07:00")
        #expect(daytime.isActive(at: try date("2026-10-16T01:00:00Z"), calendar: calendar))
        #expect(!daytime.isActive(at: try date("2026-10-16T07:00:00Z"), calendar: calendar))
    }

    @Test func daylightSavingSkippedAndRepeatedHoursHaveOneInterval() throws {
        let calendar = calendar("America/Los_Angeles")
        let spring = TransferScheduleController.Configuration(startTime: "02:30", endTime: "04:00", weekdays: [1])
        #expect(!spring.isActive(at: try date("2026-03-08T09:59:59Z"), calendar: calendar))
        #expect(spring.isActive(at: try date("2026-03-08T10:00:00Z"), calendar: calendar))
        #expect(!spring.isActive(at: try date("2026-03-08T11:00:00Z"), calendar: calendar))
        let fall = TransferScheduleController.Configuration(startTime: "01:30", endTime: "02:30", weekdays: [1])
        #expect(!fall.isActive(at: try date("2026-11-01T08:29:59Z"), calendar: calendar))
        #expect(fall.isActive(at: try date("2026-11-01T08:30:00Z"), calendar: calendar))
        #expect(fall.isActive(at: try date("2026-11-01T09:15:00Z"), calendar: calendar))
        #expect(!fall.isActive(at: try date("2026-11-01T10:30:00Z"), calendar: calendar))
        #expect(fall.nextStart(after: try date("2026-11-01T08:31:00Z"), calendar: calendar) == (try date("2026-11-08T09:30:00Z")))
    }

    @Test func invalidAndDisabledConfigurationsDoNotRun() throws {
        let calendar = calendar()
        let now = try date("2026-10-16T03:00:00Z")
        for schedule in [
            TransferScheduleController.Configuration(enabled: false, startTime: "01:00", endTime: "07:00"),
            .init(startTime: "01:00", endTime: "01:00"),
            .init(startTime: "25:00", endTime: "07:00"),
            .init(startTime: "invalid", endTime: "07:00"),
            .init(startTime: "01:00", endTime: "07:00", weekdays: [])
        ] {
            #expect(!schedule.isActive(at: now, calendar: calendar))
            #expect(schedule.nextStart(after: now, calendar: calendar) == nil)
        }
    }

    @Test func onlyScheduleAndQueueResumeWhileManualDiskAndTrashRemain() async throws {
        let defaults = try TemporaryDefaults(prefix: "TransferSchedule-")
        defer { defaults.clean() }
        let settings = SettingsModel(defaults: defaults.defaults)
        settings.transferScheduleEnabled = true
        var clock = try date("2026-10-16T00:59:00Z")
        let calendar = calendar()
        var tasks = (0..<6).map { _ in MockData.tasks[0] }
        tasks = tasks.enumerated().map { index, original in
            var task = DownloadTask(link: LinkParser.parse("https://example.com/file\(index)").first!, autoExtract: false)
            task.status = original.status
            return task
        }
        tasks[0].status = .downloading
        tasks[1].status = .queued
        tasks[2].status = .paused
        tasks[3].status = .paused
        tasks[3].pauseReason = .diskSpace
        tasks[4].status = .paused
        tasks[4].pauseReason = .schedule
        tasks[4].deletedAt = clock
        tasks[5].status = .completed
        let model = AppModel(tasks: tasks, preventsSleepWhileDownloading: false)
        let controller = TransferScheduleController(
            model: model, settings: settings, now: { clock }, calendar: { calendar }, scheduleWake: { _ in 0 }, cancelWake: { _ in 0 }, copyScheduledEvents: { [] }
        )
        await controller.refresh()
        #expect(model.tasks[0].pauseReason == .schedule)
        #expect(model.tasks[1].pauseReason == .schedule)
        #expect(model.tasks[2].pauseReason == nil)
        clock = try date("2026-10-16T01:00:00Z")
        await controller.refresh()
        #expect(model.tasks[0].status == .downloading)
        #expect(model.tasks[1].status == .downloading)
        #expect(model.tasks[2].status == .paused)
        #expect(model.tasks[3].pauseReason == .diskSpace)
        #expect(model.tasks[4].status == .paused)
        #expect(model.tasks[4].deletedAt != nil)
        #expect(model.tasks[5].status == .completed)
        clock = try date("2026-10-16T07:00:00Z")
        await controller.refresh()
        #expect(model.tasks[0].status == .paused)
        model.pause(model.tasks[0].id)
        clock = try date("2026-10-17T03:00:00Z")
        await controller.refresh()
        #expect(model.tasks[0].status == .paused)
        #expect(model.tasks[0].pauseReason == nil)
        #expect(model.tasks[1].status == .downloading)
    }

    @Test func wakeFailureExplainsImpactAndSettingsChangeReplacesOnlyOwnEvent() async throws {
        let defaults = try TemporaryDefaults(prefix: "TransferWake-")
        defer { defaults.clean() }
        let settings = SettingsModel(defaults: defaults.defaults)
        settings.transferScheduleEnabled = true
        let clock = try date("2026-10-16T00:00:00Z")
        let calendar = calendar()
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        var calls: [Date] = []
        var cancelled: [Date] = []
        var result = kIOReturnNotPrivileged
        let controller = TransferScheduleController(
            model: model, settings: settings, now: { clock }, calendar: { calendar },
            scheduleWake: { calls.append($0); return result }, cancelWake: { cancelled.append($0); return 0 }, copyScheduledEvents: { [] }
        )
        await controller.refresh()
        await controller.refresh()
        #expect(calls == [try date("2026-10-16T00:59:00Z")])
        #expect(model.transferScheduleWakeIssue?.contains("权限") == true)
        #expect(model.transferScheduleWakeIssue?.contains("下次唤醒后执行") == true)
        result = 0
        settings.transferScheduleStartTime = "02:00"
        await controller.refresh()
        #expect(model.transferScheduleWakeIssue == nil)
        #expect(calls.last == (try date("2026-10-16T01:59:00Z")))
        settings.transferScheduleEnabled = false
        await controller.refresh()
        #expect(cancelled == [try date("2026-10-16T01:59:00Z")])
        #expect(!model.isTransferScheduleActive)
    }

    @Test func startupAndScheduleChangesRemovePersistedOwnedPowerEvents() async throws {
        let defaults = try TemporaryDefaults(prefix: "TransferWakeRecovery-")
        defer { defaults.clean() }
        let settings = SettingsModel(defaults: defaults.defaults)
        let clock = try date("2026-10-16T00:00:00Z")
        let calendar = calendar()
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        typealias PowerEvent = TransferScheduleController.PowerEvent
        let owned = [
            PowerEvent(date: clock.addingTimeInterval(600), owner: "com.cqagc.mulee", type: kIOPMAutoWake),
            PowerEvent(date: clock.addingTimeInterval(1200), owner: "com.cqagc.mulee", type: kIOPMAutoWakeOrPowerOn)
        ]
        let other = PowerEvent(date: clock.addingTimeInterval(600), owner: "example.other", type: kIOPMAutoWake)
        var events = owned + [other]
        var cancelled: [PowerEvent] = []
        var scheduled: [Date] = []
        let controller = TransferScheduleController(
            model: model, settings: settings, now: { clock }, calendar: { calendar },
            scheduleWake: { scheduled.append($0); return 0 }, cancelWake: { _ in 0 },
            copyScheduledEvents: { events }, cancelPowerEvent: { event in
                cancelled.append(event)
                events.removeAll { $0 == event }
                return 0
            }
        )
        // 计划关闭的启动也必须回收上次异常退出留下的事件。
        await controller.refresh()
        #expect(cancelled == owned)
        #expect(events == [other])
        #expect(scheduled.isEmpty)

        settings.transferScheduleEnabled = true
        events.append(owned[0])
        await controller.refresh()
        #expect(cancelled == owned + [owned[0]])
        #expect(scheduled.count == 1)
        events.append(owned[1])
        settings.transferScheduleStartTime = "02:00"
        await controller.refresh()
        #expect(cancelled == owned + owned)
        #expect(scheduled.count == 2)
        events.append(owned[0])
        settings.transferScheduleEnabled = false
        await controller.refresh()
        #expect(events == [other])
        #expect(cancelled.count == 5)
        controller.stop()
    }

    @Test func coordinatorPausesAndResumesThroughTheExistingQueue() async throws {
        let defaults = try TemporaryDefaults(prefix: "TransferScheduleEngine-")
        defer { defaults.clean() }
        let settings = SettingsModel(defaults: defaults.defaults)
        settings.transferScheduleEnabled = true
        var clock = try date("2026-10-16T08:00:00Z")
        let calendar = calendar()
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        let engine = FakeEngine()
        let coordinator = DownloadCoordinator(model: model, engines: [engine])
        await coordinator.start(options: EngineOptions(downloadDirectory: URL(filePath: "/tmp")))
        await coordinator.add(links: LinkParser.parse("https://example.com/file"), autoExtract: false)
        let controller = TransferScheduleController(
            model: model, settings: settings, now: { clock }, calendar: { calendar }, scheduleWake: { _ in 0 }, cancelWake: { _ in 0 }, copyScheduledEvents: { [] }
        )
        await controller.refresh()
        #expect(await engine.pausedIDs.contains("task-1"))
        #expect(model.tasks.first?.pauseReason == .schedule)
        clock = try date("2026-10-17T01:00:00Z")
        await controller.refresh()
        #expect(await engine.resumedIDs.contains("task-1"))
        #expect(model.tasks.first?.pauseReason == nil)
        await coordinator.stop()
    }

    @Test func scheduleReasonPersistsAndSurvivesStaleEngineSnapshots() throws {
        var task = MockData.tasks[0]
        task.engineTaskID = "scheduled-1"
        task.status = .paused
        task.pauseReason = .schedule
        let data = try JSONEncoder().encode(task)
        #expect(try JSONDecoder().decode(DownloadTask.self, from: data).pauseReason == .schedule)
        let snapshot = EngineTaskSnapshot(
            engineTaskID: "scheduled-1", name: task.name, totalBytes: 100, receivedBytes: 10,
            downloadRate: 100, uploadRate: 20, status: .downloading, connections: 1,
            savePath: nil, sourceURL: nil, errorMessage: nil
        )
        let merged = EngineSnapshotMerger.merge(tasks: [task], snapshots: [task.kind: [snapshot]], now: .now)
        #expect(merged.first?.status == .paused)
        #expect(merged.first?.pauseReason == .schedule)
        #expect(merged.first?.downloadRate == 0)
    }

    @Test func scheduledSeederSurvivesCompletedSnapshotAndResumesNextWindow() async throws {
        let defaults = try TemporaryDefaults(prefix: "ScheduledSeeder-")
        defer { defaults.clean() }
        let settings = SettingsModel(defaults: defaults.defaults)
        settings.transferScheduleEnabled = true
        var clock = try date("2026-10-16T08:00:00Z")
        let calendar = calendar()
        var task = try #require(MockData.tasks.first { $0.kind == .bittorrent })
        task.engineTaskID = "scheduled-seeder"
        task.status = .seeding
        task.totalBytes = 100
        task.receivedBytes = 100
        let model = AppModel(tasks: [task], preventsSleepWhileDownloading: false)
        let engine = FakeEngine(kind: .bittorrent)
        let coordinator = DownloadCoordinator(model: model, engines: [engine])
        let snapshot = EngineTaskSnapshot(
            engineTaskID: "scheduled-seeder", name: task.name, totalBytes: 100, receivedBytes: 100,
            downloadRate: 0, uploadRate: 20, status: .seeding, connections: 1,
            savePath: nil, sourceURL: nil, errorMessage: nil
        )
        await engine.setSnapshots([snapshot])
        await coordinator.start(options: EngineOptions(downloadDirectory: URL(filePath: "/tmp")))
        let controller = TransferScheduleController(
            model: model, settings: settings, now: { clock }, calendar: { calendar }, scheduleWake: { _ in 0 }, cancelWake: { _ in 0 }, copyScheduledEvents: { [] }
        )
        await controller.refresh()
        model.tasks = EngineSnapshotMerger.merge(tasks: model.tasks, snapshots: [.bittorrent: [EngineTaskSnapshot(
            engineTaskID: "scheduled-seeder", name: task.name, totalBytes: 100, receivedBytes: 100,
            downloadRate: 0, uploadRate: 20, status: .completed, connections: 1,
            savePath: nil, sourceURL: nil, errorMessage: nil
        )]], now: clock)
        #expect(model.tasks[0].status == .paused)
        #expect(model.tasks[0].pauseReason == .schedule)
        clock = try date("2026-10-17T01:00:00Z")
        await controller.refresh()
        #expect(await engine.resumedIDs.contains("scheduled-seeder"))
        #expect(model.tasks[0].status == .seeding)
        #expect(model.tasks[0].pauseReason == nil)
        await coordinator.stop()
    }

    @Test(arguments: [DownloadTask.PauseReason.diskSpace, .schedule])
    func completedDownloadClearsPauseReason(reason: DownloadTask.PauseReason) {
        var task = MockData.tasks[0]
        task.kind = .bittorrent
        task.engineTaskID = "protected-task"
        task.status = .paused
        task.pauseReason = reason
        task.totalBytes = 100
        task.receivedBytes = 10
        let snapshot = EngineTaskSnapshot(
            engineTaskID: "protected-task", name: task.name, totalBytes: 100, receivedBytes: 100,
            downloadRate: 0, uploadRate: 0, status: .completed, connections: 1,
            savePath: nil, sourceURL: nil, errorMessage: nil
        )
        let merged = EngineSnapshotMerger.merge(tasks: [task], snapshots: [.bittorrent: [snapshot]], now: .now)
        #expect(merged.first?.pauseReason == nil)
        #expect(merged.first?.status == .completed)
    }

    @Test func defaultsAndPersistenceRemainSeparateFromScheduledSpeedLimits() throws {
        let defaults = try TemporaryDefaults(prefix: "TransferScheduleDefaults-")
        defer { defaults.clean() }
        let settings = SettingsModel(defaults: defaults.defaults)
        #expect(!settings.transferScheduleEnabled)
        #expect(settings.transferScheduleStartTime == "01:00")
        #expect(settings.transferScheduleEndTime == "07:00")
        #expect(settings.transferScheduleWeekdays == Array(1...7))
        settings.transferScheduleEnabled = true
        settings.transferScheduleStartTime = "23:00"
        settings.transferScheduleEndTime = "06:00"
        settings.transferScheduleWeekdays = [2, 4, 6]
        let restored = SettingsModel(defaults: defaults.defaults)
        #expect(restored.transferScheduleEnabled)
        #expect(restored.transferScheduleStartTime == "23:00")
        #expect(restored.transferScheduleEndTime == "06:00")
        #expect(restored.transferScheduleWeekdays == [2, 4, 6])
        #expect(!restored.scheduledLimit)
    }
}
