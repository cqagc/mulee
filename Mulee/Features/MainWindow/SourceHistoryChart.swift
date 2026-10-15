import Charts
import SwiftUI

struct SourceHistoryChart: View {
    let sightings: [Int]

    private var days: [Int] { Array(sightings.suffix(14)) }

    var body: some View {
        InspectorCard("近 14 天来源出现情况") {
            Chart(Array(days.enumerated()), id: \.offset) { day in
                BarMark(x: .value(String(localized: "日期"), day.offset), y: .value(String(localized: "来源"), max(0.2, Double(day.element))))
                    .foregroundStyle(day.element > 0 ? Theme.wait : Color.secondary.opacity(0.15))
                    .clipShape(.rect(cornerRadius: 2))
                    .accessibilityLabel(day.offset == days.count - 1 ? String(localized: "今天") : String(localized: "\(days.count - 1 - day.offset) 天前"))
                    .accessibilityValue("\(max(0, day.element)) 个来源")
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 36)
        }
    }
}
