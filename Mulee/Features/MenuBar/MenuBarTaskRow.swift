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
            // 与主窗口共用进度规则：解压中显示解压进度、等待来源显示虚线等。
            let presentation = TaskPresentation(task: task)
            TaskProgressBar(progress: presentation.progress, style: presentation.progressStyle, height: 3)
        }
    }
}

#Preview {
    MenuBarTaskRow(task: MockData.tasks[1])
        .padding()
        .frame(width: 340)
}
