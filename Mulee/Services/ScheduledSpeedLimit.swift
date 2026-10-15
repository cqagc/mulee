import Foundation

/// 工作日以时段开始所在的日期为准；周五跨午夜可延续到周六。
enum ScheduledSpeedLimit {
    static func isActive(settings: SettingsModel, now: Date, calendar: Calendar = .current) -> Bool {
        guard settings.scheduledLimit else { return false }
        let start = calendar.component(.hour, from: settings.scheduleStart) * 60
            + calendar.component(.minute, from: settings.scheduleStart)
        let end = calendar.component(.hour, from: settings.scheduleEnd) * 60
            + calendar.component(.minute, from: settings.scheduleEnd)
        let minute = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        guard start != end else { return false }
        let anchor: Date
        if start < end {
            guard minute >= start, minute < end else { return false }
            anchor = now
        } else if minute >= start {
            anchor = now
        } else {
            guard minute < end, let previous = calendar.date(byAdding: .day, value: -1, to: now) else { return false }
            anchor = previous
        }
        return (2...6).contains(calendar.component(.weekday, from: anchor))
    }
}
