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

    private let model: AppModel
    private let settings: SettingsModel
    private let now: () -> Date
    private let calendar: () -> Calendar
    private let scheduleWake: (Date) -> Int32
    private let cancelWake: (Date) -> Int32
    private var worker: Task<Void, Never>?
    private var previousConfiguration: Configuration?
    private var wasActive = false
    private var attemptedWake: Date?
    private var scheduledWake: Date?
    private var busy = false

    init(
        model: AppModel, settings: SettingsModel, now: @escaping () -> Date = Date.init,
        calendar: @escaping () -> Calendar = { .current },
        scheduleWake: @escaping (Date) -> Int32 = {
            IOPMSchedulePowerEvent($0 as CFDate, "com.cqagc.mulee.schedule" as CFString, kIOPMAutoWake as CFString)
        },
        cancelWake: @escaping (Date) -> Int32 = {
            IOPMCancelScheduledPowerEvent($0 as CFDate, "com.cqagc.mulee.schedule" as CFString, kIOPMAutoWake as CFString)
        }
    ) {
        self.model = model
        self.settings = settings
        self.now = now
        self.calendar = calendar
        self.scheduleWake = scheduleWake
        self.cancelWake = cancelWake
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
        clearWake()
    }

    isolated deinit {
        worker?.cancel()
        if let scheduledWake { _ = cancelWake(scheduledWake) }
    }

    func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let configuration = Configuration(settings: settings)
        let date = now()
        let calendar = calendar()
        let changed = configuration != previousConfiguration
        if changed {
            clearWake()
            previousConfiguration = configuration
        }
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
        updateWake(configuration.nextStart(after: date, calendar: calendar), now: date)
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
              model.tasks[index].pauseReason == nil, !model.userPausedTaskIDs.contains(id) else { return }
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
        if model.tasks[current].status != .paused || model.userPausedTaskIDs.contains(id) {
            model.tasks[current].pauseReason = nil
        }
    }

    private func resume(_ id: UUID) async {
        guard let index = model.tasks.firstIndex(where: { $0.id == id && $0.deletedAt == nil }),
              model.tasks[index].pauseReason != .diskSpace, !model.userPausedTaskIDs.contains(id),
              model.tasks[index].pauseReason == .schedule || model.tasks[index].status == .queued else { return }
        if let coordinator = model.coordinator {
            await coordinator.resume(id)
        } else {
            model.tasks[index].status = model.tasks[index].kind == .ed2k ? .waitingForSources : .downloading
        }
        if let current = model.tasks.firstIndex(where: { $0.id == id }), model.tasks[current].status != .paused,
           model.tasks[current].pauseReason == .schedule {
            model.tasks[current].pauseReason = nil
        }
    }

    private func updateWake(_ start: Date?, now: Date) {
        let wake = start?.addingTimeInterval(-60)
        guard wake != attemptedWake else { return }
        clearWake()
        attemptedWake = wake
        guard let wake, wake > now else { return }
        let result = scheduleWake(wake)
        if result == kIOReturnSuccess {
            scheduledWake = wake
            model.transferScheduleWakeIssue = nil
        } else if result == kIOReturnNotPrivileged || result == kIOReturnNotPermitted {
            model.transferScheduleWakeIssue = String(localized: "系统未授予定时唤醒权限，无法在睡眠中启动下载；计划仍会在下次唤醒后执行。")
        } else {
            model.transferScheduleWakeIssue = String(localized: "系统无法安排定时唤醒，无法在睡眠中启动下载；计划仍会在下次唤醒后执行。")
        }
    }

    private func clearWake() {
        if let scheduledWake { _ = cancelWake(scheduledWake) }
        scheduledWake = nil
        attemptedWake = nil
    }
}
