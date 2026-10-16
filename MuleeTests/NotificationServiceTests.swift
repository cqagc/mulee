import Foundation
import MuleeCore
import Testing
import UserNotifications
@testable import Mulee

@Suite @MainActor struct NotificationServiceTests {
    @Test func completionsCoalesceForTenSecondsAndAskOnlyWhenNeeded() async throws {
        let defaults = try TemporaryDefaults(prefix: "Notification-")
        defer { defaults.clean() }
        let settings = SettingsModel(defaults: defaults.defaults)
        settings.autoExtract = true
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        let center = DownloadNotificationCenterSpy()
        var now = Date(timeIntervalSince1970: 0)
        let service = NotificationService(model: model, settings: settings, center: center, now: { now })
        #expect(center.authorizationRequests == 0)
        model.tasks = LinkParser.parse("https://example.com/a.zip\nhttps://example.com/b.zip").map {
            var task = DownloadTask(link: $0, autoExtract: false)
            task.status = .completed
            return task
        }
        now += 9
        service.flushCompletionsIfDue()
        #expect(center.requests.isEmpty)
        now += 1
        service.flushCompletionsIfDue()
        await service.waitForDelivery()
        let request = try #require(center.requests.first)
        #expect(center.requests.count == 1)
        #expect(center.authorizationRequests == 1)
        #expect(request.content.title == String(localized: "2 个下载已完成"))
        #expect(request.content.categoryIdentifier == "archive")
        #expect(request.content.sound == nil)
        #expect((request.content.userInfo["taskIDs"] as? [String])?.count == 2)
        let actions = try #require(center.categories.first { $0.identifier == "archive" }).actions.map(\.identifier)
        #expect(actions == [NotificationService.openAction, NotificationService.revealAction, NotificationService.extractAction])
        model.tasks[0].status = .extracting
        model.tasks[0].status = .completed
        now += 20
        service.flushCompletionsIfDue()
        await service.waitForDelivery()
        #expect(center.requests.count == 1)
    }

    @Test func validationFailureRemovesPendingCompletionAndRetryCanNotify() async throws {
        let defaults = try TemporaryDefaults(prefix: "NotificationValidation-")
        defer { defaults.clean() }
        let settings = SettingsModel(defaults: defaults.defaults)
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        let center = DownloadNotificationCenterSpy()
        var now = Date(timeIntervalSince1970: 0)
        let service = NotificationService(model: model, settings: settings, center: center, now: { now })
        var task = MockData.tasks[0]
        task.status = .completed
        model.tasks = [task]
        model.tasks[0].status = .failed
        now += 10
        service.flushCompletionsIfDue()
        await service.waitForDelivery()
        #expect(center.requests.count == 1)
        #expect(center.requests[0].content.title == String(localized: "下载未完成"))
        model.tasks[0].status = .downloading
        model.tasks[0].status = .completed
        now += 10
        service.flushCompletionsIfDue()
        await service.waitForDelivery()
        #expect(center.requests.count == 2)
        #expect(center.requests[1].content.title == String(localized: "下载已完成"))
    }

    @Test func deniedAuthorizationSurfacesExplanationWithoutRepeatedPrompts() async throws {
        let defaults = try TemporaryDefaults(prefix: "NotificationDenied-")
        defer { defaults.clean() }
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        let settings = SettingsModel(defaults: defaults.defaults)
        let center = DownloadNotificationCenterSpy()
        center.grantsAuthorization = false
        let service = NotificationService(model: model, settings: settings, center: center)
        service.sendSystem(title: "磁盘保护", body: "请清理空间")
        service.sendSystem(title: "磁盘保护", body: "请清理空间")
        await service.waitForDelivery()
        #expect(model.notificationPermissionDenied)
        #expect(center.requests.isEmpty)
        #expect(center.authorizationRequests == 1)
    }

    @Test func cancellingCountdownPreventsLateDelivery() async throws {
        let defaults = try TemporaryDefaults(prefix: "NotificationCancel-")
        defer { defaults.clean() }
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        let settings = SettingsModel(defaults: defaults.defaults)
        let center = DownloadNotificationCenterSpy()
        let service = NotificationService(model: model, settings: settings, center: center)
        service.sendSystem(title: "下载已全部完成", body: "60 秒后退出", countdown: true)
        service.cancelCountdown()
        await service.waitForDelivery()
        #expect(center.requests.isEmpty)
        #expect(center.removedIdentifiers == [NotificationService.countdownIdentifier])
    }

    @Test func failurePreferenceAndSoundAreConsumed() async throws {
        let defaults = try TemporaryDefaults(prefix: "NotificationFailure-")
        defer { defaults.clean() }
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        let settings = SettingsModel(defaults: defaults.defaults)
        settings.notifyOnFailure = false
        let center = DownloadNotificationCenterSpy()
        let service = NotificationService(model: model, settings: settings, center: center)
        var task = MockData.tasks[0]
        task.status = .failed
        model.tasks = [task]
        await service.waitForDelivery()
        #expect(center.requests.isEmpty)
        settings.notifyOnFailure = true
        settings.notificationSound = true
        model.tasks[0].status = .downloading
        model.tasks[0].status = .failed
        await service.waitForDelivery()
        #expect(center.requests.count == 1)
        #expect(center.requests.first?.content.sound != nil)
        service.tasksDidChange()
        await service.waitForDelivery()
        #expect(center.requests.count == 1)
    }
}
