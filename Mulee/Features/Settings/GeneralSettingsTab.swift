import AppKit
import SwiftUI

/// 设置·通用。
struct GeneralSettingsTab: View {
    @Environment(SettingsModel.self) private var model
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase

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
            Section("下完后") {
                Picker("默认操作", selection: $model.whenAllDone) {
                    ForEach(WhenAllDoneAction.allCases) { action in
                        Text(action.title).tag(action)
                    }
                }
                Text("全部下载完成后倒计时 60 秒；新任务或用户操作会取消。此设置不影响「全部完成后允许睡眠」。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("通知") {
                Toggle("下载完成时通知", isOn: $model.notifyOnComplete)
                Toggle("下载失败时通知", isOn: $model.notifyOnFailure)
                Toggle("通知声音", isOn: $model.notificationSound)
                if app.notificationPermissionDenied {
                    Text("通知权限已关闭，下载完成和磁盘保护等提醒不会显示。请在系统设置中允许通知。")
                        .foregroundStyle(.secondary)
                    Button("打开系统设置") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
            DefaultHandlerSection()
            BrowserExtensionSection()
            AppUpdateSection()
            Section {
                Toggle(isOn: $model.watchClipboard) {
                    Text("监听剪贴板")
                    Text("复制链接后自动询问是否下载")
                }
            }
        }
        .formStyle(.grouped)
        .task(id: scenePhase) { await app.notificationService?.refreshAuthorization() }
    }
}

#Preview {
    GeneralSettingsTab()
        .environment(SettingsModel())
        .environment(AppModel())
}
