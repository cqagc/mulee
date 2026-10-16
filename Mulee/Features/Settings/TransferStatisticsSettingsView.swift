import Charts
import MuleeCore
import SwiftUI

struct TransferStatisticsSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingReset = false

    var body: some View {
        VStack {
            Form {
                if let store = model.transferStatistics {
                    Section("速度曲线") { TransferHistoryView(store: store) }
                    Section("累计流量") {
                        LabeledContent("总下载", value: bytes(store.total.downloaded))
                        LabeledContent("总上传", value: bytes(store.total.uploaded))
                        ForEach(TaskKind.allCases, id: \.self) { kind in
                            let traffic = store.byKind[kind.rawValue] ?? .init()
                            let fraction = store.total.downloaded > 0 ? Double(traffic.downloaded) / Double(store.total.downloaded) : 0
                            LabeledContent(kindTitle(kind)) {
                                Text("\(bytes(traffic.downloaded)) · \(fraction.formatted(.percent.precision(.fractionLength(1))))")
                            }
                        }
                        Text("类型占比按下载量计算。上传量根据引擎速度采样估算；睡眠期间不外推流量。回收站任务不参与采样，已累计的流量会保留。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Section("最近 30 天下载量") {
                        Chart(store.recentDays()) { day in
                            BarMark(x: .value(String(localized: "日期"), day.date, unit: .day), y: .value(String(localized: "下载量"), day.traffic.downloaded))
                                .accessibilityLabel(day.date.formatted(date: .abbreviated, time: .omitted))
                                .accessibilityValue(bytes(day.traffic.downloaded))
                        }
                        .chartYAxis {
                            AxisMarks { value in
                                AxisGridLine()
                                AxisValueLabel {
                                    if let count = value.as(Int64.self) { Text(bytes(count)) }
                                }
                            }
                        }
                        .frame(height: 160)
                    }
                    Section {
                        if let issue = store.issue { Text(issue).foregroundStyle(.secondary) }
                        Button("重置统计…", role: .destructive) { isConfirmingReset = true }
                    }
                } else {
                    Text("统计将在下载引擎启动后可用。")
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom])
        }
        .frame(minWidth: 520, idealWidth: 580, minHeight: 560, idealHeight: 700)
        .confirmationDialog("重置全部流量统计？", isPresented: $isConfirmingReset) {
            Button("重置统计", role: .destructive) { model.transferStatistics?.reset() }
        } message: {
            Text("累计流量、按天统计和速度曲线将清零，下载任务不受影响。")
        }
    }

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    private func kindTitle(_ kind: TaskKind) -> String {
        switch kind {
        case .http: "HTTP"
        case .bittorrent: "BT"
        case .ed2k: String(localized: "电驴")
        case .video: String(localized: "视频")
        }
    }
}
