import SwiftUI

/// 状态以文字表达，颜色只作辅助。
struct NetworkPortStatusRow: View {
    let title: String
    let port: Int
    let transport: String
    let line: NetworkPresentation.Line

    var body: some View {
        LabeledContent {
            Text(line.text)
                .foregroundStyle(line.isAbnormal ? Theme.wait : .primary)
        } label: {
            Text(title)
            Text("\(transport) \(port.formatted(.number.grouping(.never)))")
        }
    }
}
