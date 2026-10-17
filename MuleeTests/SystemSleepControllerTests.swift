import Foundation
import MuleeCore
import Testing
@testable import Mulee

@Suite @MainActor struct SystemSleepControllerTests {
    private final class NetworkGate {
        var waiter: CheckedContinuation<Void, Never>?
        var entered: CheckedContinuation<Void, Never>?
        func wait() async {
            await withCheckedContinuation { continuation in
                waiter = continuation
                entered?.resume()
                entered = nil
            }
        }
        func waitUntilEntered() async {
            if waiter != nil { return }
            await withCheckedContinuation { entered = $0 }
        }
        func release() { waiter?.resume(); waiter = nil }
    }

    @Test func sleepOnlyPausesHTTPAndVideoAndWakeWaitsForNetwork() async throws {
        let storage = try TemporaryDefaults(prefix: "SystemSleep-")
        defer { storage.clean() }
        let settings = SettingsModel(defaults: storage.defaults)
        let tasks = [TaskKind.http, .video, .bittorrent, .ed2k].map { kind in
            var task = MockData.tasks[0]
            task = DownloadTask(
                name: task.name, fileExtension: task.fileExtension, kind: kind, status: .downloading,
                totalBytes: 100, receivedBytes: 1, detail: task.detail,
                postDownload: PostDownloadInfo(autoExtract: false), sourceLink: "https://example.com/file"
            )
            return task
        }
        let model = AppModel(tasks: tasks, preventsSleepWhileDownloading: false)
        let gate = NetworkGate()
        let controller = SystemSleepController(model: model, settings: settings, waitForNetwork: { await gate.wait() })
        await controller.willSleep()
        #expect(controller.isSleeping)
        #expect(model.tasks.prefix(2).allSatisfy { $0.pauseReason == .systemSleep })
        #expect(model.tasks.suffix(2).allSatisfy { $0.status == .downloading })
        let wake = Task { await controller.didWake() }
        await gate.waitUntilEntered()
        #expect(model.tasks[0].status == .paused)
        model.pause(tasks[0].id)
        gate.release()
        await wake.value
        #expect(model.tasks[0].status == .paused)
        #expect(model.tasks[1].status == .downloading)
        #expect(!controller.isSleeping)
    }

    @Test func disabledSettingAndUserPauseAreRespected() async throws {
        let storage = try TemporaryDefaults(prefix: "SystemSleepDisabled-")
        defer { storage.clean() }
        let settings = SettingsModel(defaults: storage.defaults)
        var task = MockData.tasks[0]
        task.kind = .http
        task.status = .downloading
        let model = AppModel(tasks: [task], preventsSleepWhileDownloading: false)
        var waits = 0
        let controller = SystemSleepController(model: model, settings: settings, waitForNetwork: { waits += 1 })
        settings.pauseOnSleep = false
        await controller.willSleep()
        await controller.didWake()
        #expect(model.tasks[0].status == .downloading)
        #expect(waits == 0)
        settings.pauseOnSleep = true
        model.pause(task.id)
        await controller.willSleep()
        await controller.didWake()
        #expect(model.tasks[0].pauseReason == nil)
        #expect(model.tasks[0].status == .paused)
        #expect(waits == 0)
    }

    @Test func secondSleepInvalidatesPendingWakeAndDiskReasonStillBlocks() async throws {
        let storage = try TemporaryDefaults(prefix: "SystemSleepRace-")
        defer { storage.clean() }
        var task = MockData.tasks[0]
        task.kind = .http
        task.status = .downloading
        let model = AppModel(tasks: [task], preventsSleepWhileDownloading: false)
        let gate = NetworkGate()
        let controller = SystemSleepController(model: model, settings: SettingsModel(defaults: storage.defaults), waitForNetwork: { await gate.wait() })
        await controller.willSleep()
        let wake = Task { await controller.didWake() }
        await gate.waitUntilEntered()
        await controller.willSleep()
        gate.release()
        await wake.value
        #expect(model.tasks[0].pauseReason == .systemSleep)
        #expect(controller.isSleeping)
        await model.pauseAutomatically(task.id, reason: .diskSpace)
        let nextWake = Task { await controller.didWake() }
        await gate.waitUntilEntered()
        gate.release()
        await nextWake.value
        #expect(model.tasks[0].status == .paused)
        #expect(model.tasks[0].pauseReason == .diskSpace)
        #expect(!model.automaticPauseReasons(for: model.tasks[0]).contains(.systemSleep))
    }

    @Test func cancelledNetworkWaitDoesNotResumeAndSettingsPersist() async throws {
        let storage = try TemporaryDefaults(prefix: "SystemSleepCancel-")
        defer { storage.clean() }
        let settings = SettingsModel(defaults: storage.defaults)
        #expect(settings.pauseOnSleep)
        settings.pauseOnSleep = false
        #expect(!SettingsModel(defaults: storage.defaults).pauseOnSleep)
        settings.pauseOnSleep = true
        var task = MockData.tasks[0]
        task.kind = .http
        task.status = .paused
        task.pauseReason = .systemSleep
        let model = AppModel(tasks: [task], preventsSleepWhileDownloading: false)
        let gate = NetworkGate()
        let controller = SystemSleepController(model: model, settings: settings, waitForNetwork: { await gate.wait() })
        let wake = Task { await controller.didWake() }
        await gate.waitUntilEntered()
        wake.cancel()
        gate.release()
        await wake.value
        #expect(model.tasks[0].status == .paused)
        #expect(model.tasks[0].pauseReason == .systemSleep)
    }
}
