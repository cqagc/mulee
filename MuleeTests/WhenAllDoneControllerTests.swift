import Foundation
import MuleeCore
import Testing
@testable import Mulee

@Suite @MainActor struct WhenAllDoneControllerTests {
    @Test func waitsSixtySecondsExecutesOnceAndPreservesSleepSetting() throws {
        let defaults = try TemporaryDefaults(prefix: "WhenAllDone-")
        defer { defaults.clean() }
        let settings = SettingsModel(defaults: defaults.defaults)
        var task = MockData.tasks[0]
        task.status = .downloading
        let model = AppModel(tasks: [task], preventsSleepWhileDownloading: false)
        var now = Date(timeIntervalSince1970: 0)
        var actions: [WhenAllDoneAction] = []
        let controller = WhenAllDoneController(model: model, settings: settings, now: { now }, showsPanel: false) { actions.append($0) }
        controller.select(.sleep)
        model.tasks[0].status = .completed
        #expect(model.whenAllDoneSecondsRemaining == 60)
        now += 59
        controller.refresh()
        #expect(actions.isEmpty)
        now += 1
        controller.refresh()
        controller.refresh()
        #expect(actions == [.sleep])
        #expect(model.whenAllDoneAction == .none)
        #expect(settings.allowSleepWhenDone)
        #expect(settings.whenAllDone == .none)
    }

    @Test func newTaskCancelsCountdownAndJoinsTrackedScope() throws {
        let defaults = try TemporaryDefaults(prefix: "WhenAllDoneNew-")
        defer { defaults.clean() }
        let settings = SettingsModel(defaults: defaults.defaults)
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        var actions: [WhenAllDoneAction] = []
        let controller = WhenAllDoneController(model: model, settings: settings, showsPanel: false) { actions.append($0) }
        controller.select(.quit)
        controller.refresh()
        #expect(model.whenAllDoneSecondsRemaining == nil)
        let tasks = LinkParser.parse("https://example.com/one\nhttps://example.com/two").map { DownloadTask(link: $0, autoExtract: false) }
        model.tasks = [tasks[0]]
        model.tasks[0].status = .completed
        #expect(model.whenAllDoneSecondsRemaining == 60)
        model.tasks.append(tasks[1])
        #expect(model.whenAllDoneSecondsRemaining == nil)
        model.tasks[1].status = .completed
        #expect(model.whenAllDoneSecondsRemaining == 60)
        controller.userDidInteract()
        #expect(model.whenAllDoneAction == .none)
        #expect(model.whenAllDoneSecondsRemaining == nil)
        #expect(actions.isEmpty)
    }

    @Test func seedingAndOnlyLongTailWaitingDoNotBlockButErrorsAndExtractionDo() {
        var task = MockData.longTailTask
        let now = Date(timeIntervalSince1970: 200_000)
        task.status = .seeding
        #expect(WhenAllDoneController.isDone(task, now: now))
        task.status = .waitingForSources
        if case .ed2k(let hash, var info) = task.detail {
            info.waitingSince = now.addingTimeInterval(-86_400)
            task.detail = .ed2k(hash: hash, longTail: info)
        }
        #expect(!WhenAllDoneController.isDone(task, now: now))
        #expect(WhenAllDoneController.isDone(task, now: now.addingTimeInterval(1)))
        task.status = .failed
        #expect(!WhenAllDoneController.isDone(task, now: now))
        task.status = .paused
        #expect(!WhenAllDoneController.isDone(task, now: now))
        task.status = .completed
        task.postDownload.extractionState = .queued
        #expect(!WhenAllDoneController.isDone(task, now: now))
        task.postDownload.extractionState = .succeeded
        #expect(WhenAllDoneController.isDone(task, now: now))
    }

    @Test func temporaryChoiceAndNotificationCancellationPreserveSavedDefault() async throws {
        let defaults = try TemporaryDefaults(prefix: "WhenAllDoneDefault-")
        defer { defaults.clean() }
        let settings = SettingsModel(defaults: defaults.defaults)
        settings.whenAllDone = .sleep
        let model = AppModel(tasks: [MockData.tasks[0]], preventsSleepWhileDownloading: false)
        let center = DownloadNotificationCenterSpy()
        let notifications = NotificationService(model: model, settings: settings, center: center)
        let controller = WhenAllDoneController(model: model, settings: settings, showsPanel: false) { _ in
            Issue.record("取消后不能执行操作")
        }
        #expect(model.whenAllDoneAction == .sleep)
        controller.select(.quit)
        controller.settingsDidChange()
        #expect(model.whenAllDoneAction == .quit)
        #expect(settings.whenAllDone == .sleep)
        settings.whenAllDone = .shutdown
        controller.settingsDidChange()
        #expect(model.whenAllDoneAction == .shutdown)
        model.tasks[0].status = .completed
        #expect(model.whenAllDoneSecondsRemaining == 60)
        notifications.handleAction(NotificationService.cancelAction, taskIDs: [])
        await notifications.waitForDelivery()
        #expect(model.whenAllDoneAction == .none)
        #expect(model.whenAllDoneSecondsRemaining == nil)
        #expect(settings.whenAllDone == .shutdown)
        controller.settingsDidChange()
        #expect(model.whenAllDoneAction == .none)
    }

    @Test func systemActionFailureProducesNotification() async throws {
        let defaults = try TemporaryDefaults(prefix: "WhenAllDoneError-")
        defer { defaults.clean() }
        let settings = SettingsModel(defaults: defaults.defaults)
        var task = MockData.tasks[0]
        task.status = .downloading
        let model = AppModel(tasks: [task], preventsSleepWhileDownloading: false)
        let center = DownloadNotificationCenterSpy()
        let notifications = NotificationService(model: model, settings: settings, center: center)
        var now = Date(timeIntervalSince1970: 0)
        let controller = WhenAllDoneController(model: model, settings: settings, now: { now }, showsPanel: false) { _ in
            throw CocoaError(.featureUnsupported)
        }
        controller.select(.shutdown)
        model.tasks[0].status = .completed
        now += 60
        controller.refresh()
        await notifications.waitForDelivery()
        #expect(center.requests.last?.content.title == String(localized: "下完后操作未执行"))
        #expect(center.removedIdentifiers.contains(NotificationService.countdownIdentifier))
    }
}
