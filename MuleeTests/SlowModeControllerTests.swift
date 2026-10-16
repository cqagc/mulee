import Foundation
import Testing
@testable import Mulee

@Suite @MainActor struct SlowModeControllerTests {
    @Test func networkAutomationExplainsReasonAndAllowsManualOverride() throws {
        let defaults = try TemporaryDefaults(prefix: "SlowMode-")
        defer { defaults.clean() }
        let settings = SettingsModel(defaults: defaults.defaults)
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        let controller = SlowModeController(model: model, settings: settings)

        controller.networkChanged(expensive: true, constrained: false)
        #expect(model.isSlowModeActive)
        #expect(model.slowModeReason?.contains("按流量计费") == true)
        controller.toggle()
        controller.refresh()
        #expect(!model.isSlowModeActive)
        controller.networkChanged(expensive: false, constrained: true)
        #expect(model.isSlowModeActive)
        #expect(model.slowModeReason?.contains("低数据模式") == true)
        settings.slowModeOnExpensive = false
        controller.refresh()
        #expect(!model.isSlowModeActive)
        controller.toggle()
        #expect(model.isSlowModeActive)
        #expect(model.slowModeReason == nil)
    }

    @Test func slowModeCombinesWithScheduledAndUnlimitedRates() throws {
        let defaults = try TemporaryDefaults(prefix: "SlowModeLimits-")
        defer { defaults.clean() }
        let settings = SettingsModel(defaults: defaults.defaults)
        settings.downloadLimit = 0
        settings.uploadLimit = 0
        let slow = EngineOptionsMapper.options(from: settings, slowMode: true)
        #expect(slow.downloadLimit == 1_000_000)
        #expect(slow.uploadLimit == 200_000)
        #expect(EngineOptionsMapper.options(from: settings).downloadLimit == 0)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 12)))
        settings.scheduleStart = try #require(calendar.date(bySettingHour: 9, minute: 0, second: 0, of: date))
        settings.scheduleEnd = try #require(calendar.date(bySettingHour: 18, minute: 0, second: 0, of: date))
        settings.scheduledLimit = true
        settings.scheduledDownloadLimit = 5
        settings.scheduledUploadLimit = 0.1
        let options = EngineOptionsMapper.options(from: settings, now: date, calendar: calendar, slowMode: true)
        #expect(options.downloadLimit == 1_000_000)
        #expect(options.uploadLimit == 100_000)
        settings.slowModeDownloadMBps = 8
        #expect(EngineOptionsMapper.options(from: settings, now: date, calendar: calendar, slowMode: true).downloadLimit == 5_000_000)
    }

    @Test func toggleAppliesThroughExistingRuntimeWithoutAWindow() throws {
        let defaults = try TemporaryDefaults(prefix: "SlowModeRuntime-")
        defer { defaults.clean() }
        let settings = SettingsModel(defaults: defaults.defaults)
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        var limits: [Int64] = []
        let runtime = SettingsRuntime(model: model, settings: settings) { limits.append($0.downloadLimit) }
        model.settingsRuntime = runtime
        let controller = SlowModeController(model: model, settings: settings)
        runtime.refresh()
        controller.toggle()
        controller.toggle()
        #expect(limits == [0, 1_000_000, 0])
        controller.networkChanged(expensive: true, constrained: false)
        #expect(limits.last == 1_000_000)
    }

    @Test func newDefaultsPersistWithoutChangingSleepPreference() throws {
        let defaults = try TemporaryDefaults(prefix: "SystemSettings-")
        defer { defaults.clean() }
        let settings = SettingsModel(defaults: defaults.defaults)
        #expect(settings.diskReserveEnabled)
        #expect(settings.diskReserveGB == 10)
        #expect(settings.notifyOnComplete && settings.notifyOnFailure)
        #expect(!settings.notificationSound)
        #expect(settings.whenAllDone == .none)
        #expect(settings.slowModeOnExpensive)
        #expect(settings.slowModeDownloadMBps == 1)
        #expect(settings.slowModeUploadMBps == 0.2)
        settings.whenAllDone = .shutdown
        settings.diskReserveGB = 25
        settings.slowModeUploadMBps = 0.3
        let restored = SettingsModel(defaults: defaults.defaults)
        #expect(restored.whenAllDone == .shutdown)
        #expect(restored.diskReserveGB == 25)
        #expect(restored.slowModeUploadMBps == 0.3)
        #expect(restored.allowSleepWhenDone)
        settings.diskReserveGB = 0
        #expect(settings.diskReserveGB == 1)
        settings.diskReserveGB = 999
        #expect(settings.diskReserveGB == 500)
    }
}
