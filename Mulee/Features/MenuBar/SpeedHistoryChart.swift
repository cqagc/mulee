import Charts
import SwiftUI

/// 最近 30 次采样的下载速度柱状图。
struct SpeedHistoryChart: View {
    let samples: [Int64]

    var body: some View {
        Chart(Array(samples.enumerated()), id: \.offset) { index, rate in
            BarMark(
                x: .value("采样", index),
                y: .value("速度", rate)
            )
            .foregroundStyle(Color.accentColor.opacity(0.55))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 34)
        .accessibilityLabel("最近下载速度曲线")
    }
}

#Preview {
    SpeedHistoryChart(samples: (0..<30).map { Int64($0) * 1_000_000 })
        .padding()
        .frame(width: 340)
}
