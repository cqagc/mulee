import SwiftUI

/// 设置·通用中的 App 更新偏好，直接读写 Sparkle updater。
struct AppUpdateSection: View {
    @State private var updates = AppUpdateController.shared

    var body: some View {
        @Bindable var updates = updates
        Section("更新") {
            Toggle("自动检查更新", isOn: $updates.automaticallyChecksForUpdates)
            Toggle("自动下载并安装更新", isOn: $updates.automaticallyDownloadsUpdates)
                .disabled(!updates.automaticallyChecksForUpdates)
            LabeledContent("当前版本") {
                Text(verbatim: version)
                    .foregroundStyle(.secondary)
            }
            Button("现在检查", action: updates.checkForUpdates)
                .disabled(!updates.canCheckForUpdates)
            if let issue = updates.issue {
                Text(issue)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "—"
        let build = info["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }
}

#Preview {
    Form {
        AppUpdateSection()
    }
    .formStyle(.grouped)
}
