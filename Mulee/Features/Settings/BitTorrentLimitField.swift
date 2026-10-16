import SwiftUI

struct BitTorrentLimitField: View {
    let title: LocalizedStringKey
    @Binding var minutes: Int

    var body: some View {
        LabeledContent(title) {
            HStack {
                TextField(title, value: $minutes, format: .number.grouping(.never))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                    .onChange(of: minutes) { if minutes < 0 { minutes = 0 } }
                Text(minutes == 0 ? String(localized: "不限") : String(localized: "分钟"))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
