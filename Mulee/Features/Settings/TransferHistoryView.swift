import SwiftUI

struct TransferHistoryView: View {
    let store: TransferStatisticsStore
    @State private var range: TransferStatisticsStore.HistoryRange = .tenMinutes

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("速度曲线范围", selection: $range) {
                ForEach(TransferStatisticsStore.HistoryRange.allCases) { range in
                    Text(range.title).tag(range)
                }
            }
            .pickerStyle(.segmented)
            let samples = store.history(range)
            let window = store.historyWindow(range)
            Label("下载", systemImage: "arrow.down")
                .font(.caption)
            SpeedHistoryChart(samples: samples.map(\.download), dates: samples.map(\.date), timeRange: window)
            Label("上传", systemImage: "arrow.up")
                .font(.caption)
            SpeedHistoryChart(samples: samples.map(\.upload), isUpload: true, dates: samples.map(\.date), timeRange: window)
        }
    }
}
