import SwiftUI

/// 提示有电驴任务在等待来源。数量为 0 时不显示。
struct MenuBarWaitingNotice: View {
    let count: Int

    var body: some View {
        if count > 0 {
            HStack(spacing: 8) {
                Circle()
                    .fill(Theme.wait)
                    .frame(width: 7, height: 7)
                Text("\(count) 个电驴任务在等待来源，挂着就好")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    MenuBarWaitingNotice(count: 2)
        .padding()
}
