import MuleeCore
import SwiftUI

/// 与侧边栏共用电驴、Kad 展示文案。
struct Ed2kNetworkStatusView: View {
    let status: NetworkStatus

    var body: some View {
        HStack(spacing: 16) {
            Text("电驴 · \(EngineStatusPresentation.ed2k(status.ed2kID))")
            Text("Kad · \(EngineStatusPresentation.kad(status.kad))")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}
