import AppKit
import SwiftUI

/// 设置·通用。
struct GeneralSettingsTab: View {
    @Environment(SettingsModel.self) private var model
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var isShowingStatistics = false
    @State private var shortcuts: [String] = []
    @State private var shortcutIssue: String?
    @State private var shortcutRefresh = 0

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
                Picker("Dock 徽标", selection: $model.dockBadge) {
                    ForEach(DockPresenter.Badge.allCases) { badge in
                        Text(badge.title).tag(badge)
                    }
                }
                Text("仅在显示 Dock 图标时生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("睡眠") {
                Toggle("下载时阻止睡眠", isOn: $model.preventSleep)
                Toggle("系统睡眠时暂停 HTTP 和视频下载", isOn: $model.pauseOnSleep)
                Text("唤醒后等待网络连接，最多 30 秒，再继续这些下载；BT 和电驴不受影响。低电量模式下不阻止系统睡眠。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            Section("完成后运行快捷指令") {
                Picker("快捷指令", selection: $model.completionShortcut) {
                    Text("不运行").tag("")
                    if !model.completionShortcut.isEmpty, !shortcuts.contains(model.completionShortcut) {
                        Text(model.completionShortcut).tag(model.completionShortcut)
                    }
                    ForEach(shortcuts, id: \.self) { name in Text(name).tag(name) }
                }
                Button("刷新快捷指令列表") { shortcutRefresh += 1 }
                if let shortcutIssue {
                    Text(shortcutIssue).foregroundStyle(.secondary)
                }
                Text("每个任务完成后运行一次，并传入成品路径；多个任务依次运行。选择「不运行」可清空。")
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
            Section("传输统计") {
                Button("查看速度曲线与统计…") { isShowingStatistics = true }
            }
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
        .sheet(isPresented: $isShowingStatistics) { TransferStatisticsSettingsView() }
        .task(id: scenePhase) { await app.notificationService?.refreshAuthorization() }
        .task(id: shortcutRefresh) {
            do {
                shortcuts = try await CompletionShortcutRunner.list()
                shortcutIssue = nil
            } catch is CancellationError {
                return
            } catch {
                shortcutIssue = String(localized: "暂时无法读取快捷指令：\(error.localizedDescription) 请点击刷新重试。")
            }
        }
    }
}

#if DEBUG
#Preview {
    GeneralSettingsTab()
        .environment(SettingsModel())
        .environment(AppModel())
}

#endif
