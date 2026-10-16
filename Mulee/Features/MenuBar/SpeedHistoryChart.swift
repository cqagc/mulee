import Charts
import SwiftUI

/// 时间轴保留采样间隙，睡眠前后的点不会被挤成连续传输。
struct SpeedHistoryChart: View {
    let samples: [Int64]
    var isUpload = false
    var dates: [Date] = []
    var timeRange: ClosedRange<Date>?

    var body: some View {
        Chart(Array(samples.enumerated()), id: \.offset) { index, rate in
            BarMark(
                x: .value(String(localized: "采样"), dates.indices.contains(index) ? dates[index] : Date(timeIntervalSince1970: Double(index))),
                y: .value(String(localized: "速度"), rate)
            )
            .foregroundStyle(Color.accentColor.opacity(0.55))
        }
        .chartXAxis(.hidden)
        .chartXScale(domain: timeRange ?? Date(timeIntervalSince1970: 0)...Date(timeIntervalSince1970: Double(max(1, samples.count - 1))))
        .chartYAxis(.hidden)
        .frame(height: 34)
        .accessibilityLabel(isUpload ? "最近上传速度曲线" : "最近下载速度曲线")
        .accessibilityValue("\(ByteCountFormatter.string(fromByteCount: samples.last ?? 0, countStyle: .file))/s")
    }
}

#if DEBUG
#Preview {
    SpeedHistoryChart(samples: (0..<30).map { Int64($0) * 1_000_000 })
        .padding()
        .frame(width: 340)
}
#endif
