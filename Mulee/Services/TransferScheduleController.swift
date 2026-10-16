import Foundation
import IOKit.pwr_mgt
import MuleeCore

/// 星期属于开始日；用日历构造边界，避免夏令时当天按 86400 秒推算。
@MainActor
final class TransferScheduleController {
    struct Configuration: Equatable {
        var enabled: Bool
        var startTime: String
        var endTime: String
        var weekdays: [Int]

        init(settings: SettingsModel) {
            enabled = settings.transferScheduleEnabled
            startTime = settings.transferScheduleStartTime
            endTime = settings.transferScheduleEndTime
            weekdays = settings.transferScheduleWeekdays
        }

        init(enabled: Bool = true, startTime: String, endTime: String, weekdays: [Int] = Array(1...7)) {
            self.enabled = enabled
            self.startTime = startTime
            self.endTime = endTime
            self.weekdays = weekdays
        }

        var isValid: Bool {
            guard let start = Self.minutes(startTime), let end = Self.minutes(endTime) else { return false }
            return start != end && weekdays.contains { (1...7).contains($0) }
        }

        static func minutes(_ text: String) -> Int? {
            let parts = text.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
                  (0...23).contains(hour), (0...59).contains(minute) else { return nil }
            return hour * 60 + minute
        }

        func interval(on day: Date, calendar: Calendar) -> DateInterval? {
            guard enabled, isValid, weekdays.contains(calendar.component(.weekday, from: day)),
                  let start = Self.minutes(startTime), let end = Self.minutes(endTime) else { return nil }
            let midnight = calendar.startOfDay(for: day)
            guard let endDay = calendar.date(byAdding: .day, value: end < start ? 1 : 0, to: midnight),
                  let startDate = boundary(start, on: midnight, calendar: calendar),
                  let endDate = boundary(end, on: endDay, calendar: calendar), endDate > startDate else { return nil }
            return DateInterval(start: startDate, end: endDate)
        }

        func isActive(at date: Date, calendar: Calendar) -> Bool {
            for offset in [-1, 0] {
                guard let day = calendar.date(byAdding: .day, value: offset, to: date),
                      let interval = interval(on: day, calendar: calendar) else { continue }
                if date >= interval.start && date < interval.end { return true }
            }
            return false
        }

        func nextStart(after date: Date, calendar: Calendar) -> Date? {
            for offset in 0...8 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: date),
                      let interval = interval(on: day, calendar: calendar), interval.start > date else { continue }
                return interval.start
            }
            return nil
        }

        private func boundary(_ minutes: Int, on day: Date, calendar: Calendar) -> Date? {
            // 跳过的时刻顺延到首个有效时刻；重复的时刻只执行第一次。
            calendar.nextDate(
                after: day.addingTimeInterval(-1), matching: DateComponents(hour: minutes / 60, minute: minutes % 60, second: 0),
                matchingPolicy: .nextTime, repeatedTimePolicy: .first
            )
        }
    }

    nonisolated struct PowerEvent: Equatable, Sendable {
        let date: Date
        let owner: String
        let type: String
    }

    static let wakeOwner = "com.cqagc.mulee"

    nonisolated static func scheduledPowerEvents() -> [PowerEvent] {
        let events = IOPMCopyScheduledPowerEvents()?.takeRetainedValue() as? [[String: Any]] ?? []
        return events.compactMap { event in
            guard let date = event[kIOPMPowerEventTimeKey] as? Date,
                  let owner = event[kIOPMPowerEventAppNameKey] as? String,
                  let type = event[kIOPMPowerEventTypeKey] as? String else { return nil }
            return PowerEvent(date: date, owner: owner, type: type)
        }
    }

    private let model: AppModel
    private let settings: SettingsModel
    private let now: () -> Date
    private let calendar: () -> Calendar
    private let powerAssertions: any PowerAssertionProviding
    private var sleepAssertion: UInt32?
    private var cleanedLegacyWakeEvents = false
    private let copyScheduledEvents: () -> [PowerEvent]
    private let cancelPowerEvent: (PowerEvent) -> Int32
    private var worker: Task<Void, Never>?
    private var previousConfiguration: Configuration?
    private var wasActive = false
    private var busy = false

    init(
        model: AppModel, settings: SettingsModel, now: @escaping () -> Date = Date.init,
        calendar: @escaping () -> Calendar = { .current },
        powerAssertions: any PowerAssertionProviding = IOKitPowerAssertionProvider(),
        copyScheduledEvents: @escaping () -> [PowerEvent] = TransferScheduleController.scheduledPowerEvents,
        cancelPowerEvent: @escaping (PowerEvent) -> Int32 = {
            IOPMCancelScheduledPowerEvent($0.date as CFDate, $0.owner as CFString, $0.type as CFString)
        }
    ) {
        self.model = model
        self.settings = settings
        self.now = now
        self.calendar = calendar
        self.powerAssertions = powerAssertions
        self.copyScheduledEvents = copyScheduledEvents
        self.cancelPowerEvent = cancelPowerEvent
    }

    func start() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
            }
        }
    }

    func stop() {
        worker?.cancel()
        worker = nil
        releaseSleepAssertion()
    }

    isolated deinit {
        worker?.cancel()
        if let sleepAssertion { powerAssertions.releaseAssertion(sleepAssertion) }
    }

    func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        cleanLegacyWakeEventsOnce()
        let configuration = Configuration(settings: settings)
        let date = now()
        let calendar = calendar()
        let changed = configuration != previousConfiguration
        if changed {
            previousConfiguration = configuration
        }
        updateSleepAssertion(configuration, at: date, calendar: calendar)
        guard configuration.enabled else {
            model.transferScheduleWakeIssue = nil
            model.isTransferScheduleActive = false
            wasActive = false
            return
        }
        guard configuration.isValid else {
            model.transferScheduleWakeIssue = String(localized: "请选择不同的开始、结束时间和至少一天；下载计划尚未执行。")
            model.isTransferScheduleActive = false
            wasActive = false
            return
        }
        let active = configuration.isActive(at: date, calendar: calendar)
        let entering = active && (!wasActive || changed)
        wasActive = active
        model.isTransferScheduleActive = active

        for task in model.activeTasks {
            guard !Task.isCancelled else { return }
            if active {
                if task.pauseReason == .schedule || (entering && task.status == .queued) {
                    await resume(task.id)
                }
            } else if [.downloading, .queued, .waitingForSources, .seeding].contains(task.status) {
                await pause(task.id)
            }
        }
    }

    private func pause(_ id: UUID) async {
        guard let index = model.tasks.firstIndex(where: { $0.id == id && $0.deletedAt == nil }),
              (model.tasks[index].pauseReason == nil || model.tasks[index].pauseReason == .schedule), !model.userPausedTaskIDs.contains(id) else { return }
        model.tasks[index].pauseReason = .schedule
        if let coordinator = model.coordinator {
            await coordinator.pause(id)
        } else {
            model.tasks[index].status = .paused
            model.tasks[index].downloadRate = 0
            model.tasks[index].uploadRate = 0
        }
        guard let current = model.tasks.firstIndex(where: { $0.id == id }),
              model.tasks[current].pauseReason == .schedule else { return }
        if model.userPausedTaskIDs.contains(id) {
            model.tasks[current].pauseReason = nil
        }
    }

    private func resume(_ id: UUID) async {
        guard let index = model.tasks.firstIndex(where: { $0.id == id && $0.deletedAt == nil }),
              model.tasks[index].pauseReason != .diskSpace, !model.userPausedTaskIDs.contains(id),
              model.tasks[index].pauseReason == .schedule || model.tasks[index].status == .queued else { return }
        let wasScheduled = model.tasks[index].pauseReason == .schedule
        model.tasks[index].pauseReason = nil
        if let coordinator = model.coordinator {
            await coordinator.resume(id)
        } else {
            model.tasks[index].status = model.tasks[index].kind == .ed2k ? .waitingForSources : .downloading
        }
        if wasScheduled, let current = model.tasks.firstIndex(where: { $0.id == id }),
           model.tasks[current].status == .paused, model.tasks[current].pauseReason == nil,
           !model.userPausedTaskIDs.contains(id) {
            model.tasks[current].pauseReason = .schedule
        }
    }

    private func updateSleepAssertion(_ configuration: Configuration, at date: Date, calendar: Calendar) {
        let startsSoon = configuration.nextStart(after: date, calendar: calendar).map {
            $0.timeIntervalSince(date) <= 10 * 60
        } ?? false
        guard settings.preventSleepBeforeScheduleStart, configuration.enabled, configuration.isValid,
              configuration.isActive(at: date, calendar: calendar) || startsSoon else {
            releaseSleepAssertion()
            return
        }
        // 使用独立 ID，完成下载释放的断言不会覆盖计划的断言。
        if sleepAssertion == nil {
            sleepAssertion = powerAssertions.createAssertion(reason: "Mulee transfer schedule")
        }
        model.transferScheduleWakeIssue = sleepAssertion == nil
            ? String(localized: "暂时无法阻止电脑空闲睡眠；计划只在电脑醒着时执行。") : nil
    }

    private func releaseSleepAssertion() {
        if let sleepAssertion { powerAssertions.releaseAssertion(sleepAssertion) }
        sleepAssertion = nil
        model.transferScheduleWakeIssue = nil
    }

    private func cleanLegacyWakeEventsOnce() {
        guard !cleanedLegacyWakeEvents else { return }
        cleanedLegacyWakeEvents = true
        // 仅启动时清理旧版本遗留事件，不再创建任何定时唤醒。
        for event in copyScheduledEvents() where event.owner == Self.wakeOwner || event.owner == "com.cqagc.mulee.schedule" {
            _ = cancelPowerEvent(event)
        }
    }
}
