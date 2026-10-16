import Foundation
import MuleeCore
import Testing
@testable import Mulee

@Suite @MainActor struct SettingsRuntimeTests {
    private final class Power: PowerAssertionProviding {
        var creates = 0
        var releases = 0
        func createAssertion(reason: String) -> UInt32? {
            creates += 1
            return 1
        }
        func releaseAssertion(_ id: UInt32) {
            releases += 1
        }
    }

    private final class Pasteboard: ClipboardReading {
        var changeCount: Int {
            Issue.record("关闭时不能读剪贴板")
            return 0
        }
        var typeNames: Set<String> { [] }
        func plainText() -> String? {
            nil
        }
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) throws -> Date {
        try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute)))
    }

    @Test func scheduleBoundariesAndOvernight() throws {
        let temporaryDefaults = try TemporaryDefaults(prefix: "SettingsSchedule-")
        defer { temporaryDefaults.clean() }
        let defaults = temporaryDefaults.defaults
        let settings = SettingsModel(defaults: defaults)
        #expect(!settings.scheduledLimit)
        settings.scheduledLimit = true
        settings.scheduleStart = try date(16, 9)
        settings.scheduleEnd = try date(16, 18)
        #expect(!ScheduledSpeedLimit.isActive(settings: settings, now: try date(16, 8, 59), calendar: calendar))
        #expect(ScheduledSpeedLimit.isActive(settings: settings, now: try date(16, 9), calendar: calendar))
        #expect(!ScheduledSpeedLimit.isActive(settings: settings, now: try date(16, 18), calendar: calendar))
        #expect(!ScheduledSpeedLimit.isActive(settings: settings, now: try date(17, 10), calendar: calendar))
        settings.scheduleStart = try date(16, 22)
        settings.scheduleEnd = try date(16, 6)
        #expect(ScheduledSpeedLimit.isActive(settings: settings, now: try date(17, 1), calendar: calendar))
        #expect(!ScheduledSpeedLimit.isActive(settings: settings, now: try date(17, 6), calendar: calendar))
        #expect(!ScheduledSpeedLimit.isActive(settings: settings, now: try date(19, 1), calendar: calendar))
        settings.scheduleEnd = settings.scheduleStart
        #expect(!ScheduledSpeedLimit.isActive(settings: settings, now: try date(16, 22), calendar: calendar))
    }

    @Test func injectedClockUpdatesOptionsWithoutAWindow() throws {
        let temporaryDefaults = try TemporaryDefaults(prefix: "SettingsRuntime-")
        defer { temporaryDefaults.clean() }
        let defaults = temporaryDefaults.defaults
        let settings = SettingsModel(defaults: defaults)
        settings.scheduledLimit = true
        // Runtime uses the local calendar, just as the DatePickers do.
        settings.scheduleStart = try #require(Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: date(16, 12)))
        settings.scheduleEnd = try #require(Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: date(16, 12)))
        var now = try #require(Calendar.current.date(bySettingHour: 8, minute: 59, second: 0, of: date(16, 12)))
        settings.downloadLimit = 20
        settings.uploadLimit = 10
        settings.scheduledDownloadLimit = 5
        settings.scheduledUploadLimit = 0.5
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        var applied: [EngineOptions] = []
        let runtime = SettingsRuntime(model: model, settings: settings, pasteboard: Pasteboard(), now: { now }) { applied.append($0) }
        runtime.refresh()
        now += 60
        runtime.refresh()
        runtime.refresh()
        #expect(applied.map(\.downloadLimit) == [20_000_000, 5_000_000])
        #expect(applied.last?.uploadLimit == 500_000)
        #expect(model.isScheduledLimitActive)
        settings.scheduledLimit = false
        runtime.refresh()
        #expect(applied.last?.downloadLimit == 20_000_000)
        #expect(!model.isScheduledLimitActive)
        settings.saveDirectory = "/tmp/settings-chosen"
        #expect(EngineOptionsMapper.options(from: settings).downloadDirectory.path == settings.saveDirectory)
        #expect(SettingsModel.defaultSaveDirectory.hasSuffix("/Downloads/Mulee"))
    }

    @Test func sleepRulesDistinguishSeedingAndLongTailWaiting() {
        let power = Power()
        let preventer = SleepPreventer(provider: power)
        let model = AppModel(tasks: [], sleepPreventer: preventer)
        var task = MockData.tasks[0]
        task.status = .seeding
        model.tasks = [task]
        #expect(!model.isPreventingSleep)
        model.allowsSleepWhenDone = false
        #expect(model.isPreventingSleep)
        model.allowsSleepWhenDone = true
        #expect(!model.isPreventingSleep)
        task.kind = .ed2k
        task.status = .waitingForSources
        model.tasks = [task]
        #expect(!model.isPreventingSleep)
        model.allowsSleepWhenDone = false
        #expect(model.isPreventingSleep)
        model.preventsSleepWhileDownloading = false
        #expect(!model.isPreventingSleep)
        model.preventsSleepWhileDownloading = true
        model.allowsSleepWhenDone = true
        for status in [TaskStatus.downloading, .queued, .extracting, .postProcessing] {
            task.status = status
            model.tasks = [task]
            #expect(model.isPreventingSleep)
        }
        for status in [TaskStatus.paused, .completed, .failed] {
            task.status = status
            model.tasks = [task]
            #expect(!model.isPreventingSleep)
        }
    }

    @Test func lastMainWindowAndConfirmationRules() {
        #expect(!WindowClosePolicy.shouldQuit(closeKeepsRunning: true, mainWindowCount: 1))
        #expect(!WindowClosePolicy.shouldQuit(closeKeepsRunning: false, mainWindowCount: 2))
        #expect(WindowClosePolicy.shouldQuit(closeKeepsRunning: false, mainWindowCount: 1))
        var task = MockData.tasks[0]
        task.status = .downloading
        #expect(WindowClosePolicy.needsConfirmation(tasks: [task]))
        task.status = .completed
        #expect(!WindowClosePolicy.needsConfirmation(tasks: [task]))
    }
}
