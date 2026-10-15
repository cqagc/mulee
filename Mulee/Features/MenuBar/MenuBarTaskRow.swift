import MuleeCore
import SwiftUI

/// 面板里的一行任务：名称 + 右侧速度或状态 + 3pt 细进度条。
struct MenuBarTaskRow: View {
    let task: DownloadTask

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(task.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(MenuBarPresentation.trailingText(for: task))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .font(.callout)
            ProgressView(value: task.fractionCompleted ?? 0)
                .progressViewStyle(.linear)
                .tint(task.status == .extracting ? Theme.success : Color.accentColor)
                .controlSize(.mini)
                .accessibilityLabel(task.name)
        }
    }
}

#Preview {
    MenuBarTaskRow(task: MockData.tasks[1])
        .padding()
        .frame(width: 340)
}
