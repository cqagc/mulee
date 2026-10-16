import SwiftUI

struct TransferScheduleSettingsSection: View {
    @Environment(SettingsModel.self) private var settings
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = settings
        Section("下载计划（自动暂停与继续）") {
            Toggle("启用下载计划", isOn: $settings.transferScheduleEnabled)
            Group {
                TextField("开始时间（HH:mm）", text: $settings.transferScheduleStartTime)
                TextField("结束时间（HH:mm）", text: $settings.transferScheduleEndTime)
                HStack {
                    Text("开始日")
                    Spacer()
                    ForEach(orderedWeekdays, id: \.self) { weekday in
                        Toggle(Calendar.current.veryShortWeekdaySymbols[weekday - 1], isOn: weekdayBinding(weekday))
                            .toggleStyle(.button)
                            .accessibilityLabel(Calendar.current.weekdaySymbols[weekday - 1])
                    }
                }
            }
            .disabled(!settings.transferScheduleEnabled)
            Text("开始时只恢复计划暂停和排队的任务；结束时暂停传输。跨午夜时，星期按开始日计算。手动暂停、磁盘保护和回收站任务不会自动恢复。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("此计划控制下载启停；网络设置中的「计划限速」只调整速度，两者可同时使用。Mulee 需要保持运行。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if settings.transferScheduleEnabled {
                if let issue = model.transferScheduleWakeIssue {
                    Text(issue).foregroundStyle(.secondary)
                } else {
                    Text(model.isTransferScheduleActive ? "当前处于下载时段" : "当前处于暂停时段")
                        .foregroundStyle(.secondary)
                    Text("将在开始前 1 分钟请求系统唤醒；系统关闭或 Mulee 已退出时无法执行计划。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var orderedWeekdays: [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }

    private func weekdayBinding(_ weekday: Int) -> Binding<Bool> {
        Binding(
            get: { settings.transferScheduleWeekdays.contains(weekday) },
            set: { included in
                var days = Set(settings.transferScheduleWeekdays)
                if included { days.insert(weekday) } else { days.remove(weekday) }
                settings.transferScheduleWeekdays = days.sorted()
            }
        )
    }
}
