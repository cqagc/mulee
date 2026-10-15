import SwiftUI

/// 设置·通用。
struct GeneralSettingsTab: View {
    @Environment(SettingsModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                LabeledContent("界面语言") {
                    Text("跟随系统")
                        .foregroundStyle(.secondary)
                }
                Toggle("关闭窗口后继续在菜单栏运行", isOn: $model.closeKeepsRunning)
                LoginItemSection()
            }
            Section("睡眠") {
                Toggle("下载时阻止睡眠", isOn: $model.preventSleep)
                Toggle(isOn: $model.allowSleepWhenDone) {
                    Text("全部完成后允许睡眠")
                    Text("开启时，做种和电驴等待来源不阻止睡眠；关闭时，这些任务也会阻止睡眠。仅在「下载时阻止睡眠」开启时生效。")
                }
                .disabled(!model.preventSleep)
            }
            DefaultHandlerSection()
            BrowserExtensionSection()
            Section {
                Toggle(isOn: $model.watchClipboard) {
                    Text("监听剪贴板")
                    Text("复制链接后自动询问是否下载")
                }
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    GeneralSettingsTab()
        .environment(SettingsModel())
}
