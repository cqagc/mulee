import SwiftUI

/// 面板顶部的实时速度：大号下载速度 + 较小的上传速度。
struct MenuBarSpeedHeader: View {
    let downloadRate: Int64
    let uploadRate: Int64

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            Text("↓ \(MenuBarPresentation.speedText(downloadRate))")
                .font(.title2.bold())
                .foregroundStyle(.primary)
            Text("↑ \(MenuBarPresentation.speedText(uploadRate))")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .monospacedDigit()
        .lineLimit(1)
    }
}

#Preview {
    MenuBarSpeedHeader(downloadRate: 19_500_000, uploadRate: 421_888)
        .padding()
}
