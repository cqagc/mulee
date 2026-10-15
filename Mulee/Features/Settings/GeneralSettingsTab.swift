import SwiftUI

/// 设置·通用。
struct GeneralSettingsTab: View {
    @Environment(SettingsModel.self) private var model
    @State private var isConfirmingDefaultHandler = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                LabeledContent("界面语言") {
                    Text("跟随系统")
                        .foregroundStyle(.secondary)
                }
                Toggle("关闭窗口后继续在菜单栏运行", isOn: $model.closeKeepsRunning)
                Toggle("开机启动", isOn: $model.launchAtLogin)
            }
            Section("睡眠") {
                Toggle("下载时阻止睡眠", isOn: $model.preventSleep)
                Toggle("全部完成后允许睡眠", isOn: $model.allowSleepWhenDone)
            }
            Section("默认打开方式") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("让 Mulee 接管 magnet、ed2k、thunder 链接和 .torrent 文件，点击后直接在这里下载。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("设为 magnet / ed2k / thunder / .torrent 的默认打开程序…") {
                        isConfirmingDefaultHandler = true
                    }
                }
            }
            Section {
                Toggle(isOn: $model.watchClipboard) {
                    Text("监听剪贴板")
                    Text("复制链接后自动询问是否下载")
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("设为默认打开程序？", isPresented: $isConfirmingDefaultHandler) {
            Button("设为默认", action: setAsDefaultHandler)
            Button("取消", role: .cancel) {}
        } message: {
            Text("Mulee 会接管 magnet:、ed2k://、thunder:// 链接和 .torrent 文件。之后点击这些链接，会直接在 Mulee 里新建下载。")
        }
    }

    private func setAsDefaultHandler() {
        // TODO: 用 NSWorkspace.setDefaultApplication(at:toOpenURLsWithScheme:) 和 content type 接管，暂不执行。
    }
}

#Preview {
    GeneralSettingsTab()
        .environment(SettingsModel())
}
