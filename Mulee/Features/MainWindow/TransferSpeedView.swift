import SwiftUI

struct TransferSpeedView: View {
    let downloadRate: Int64
    let uploadRate: Int64

    var body: some View {
        HStack(spacing: 12) {
            Text("↓ \(TaskPresentation.rate(downloadRate))")
                .accessibilityLabel("下载速度 \(TaskPresentation.rate(downloadRate))")
            Text("↑ \(TaskPresentation.rate(uploadRate))")
                .accessibilityLabel("上传速度 \(TaskPresentation.rate(uploadRate))")
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .fixedSize()
    }
}
