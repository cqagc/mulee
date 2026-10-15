import MuleeCore
import SwiftUI

struct VideoLoginStatusView: View {
    let site: VideoSite
    let updatedAt: Date?
    let clear: () -> Void

    var body: some View {
        LabeledContent(site == .bilibili ? "B 站" : "YouTube") {
            if let updatedAt {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(site == .bilibili ? String(localized: "已有 B 站登录状态") : String(localized: "已有 YouTube 登录状态"))
                    Text("更新时间：\(updatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("清除", action: clear)
                    .accessibilityLabel(site == .bilibili ? String(localized: "清除 B 站登录状态") : String(localized: "清除 YouTube 登录状态"))
            } else {
                Text("尚未接收登录状态")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
