import AppKit
import SwiftUI

struct BitTorrentWatchSettingsSection: View {
    @Environment(SettingsModel.self) private var settings
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = settings
        Section("监视文件夹") {
            Text("文件写入完成后添加种子或磁力链接，成功后移到 .mulee-added 文件夹。")
                .foregroundStyle(.secondary)
            ForEach(settings.watchFolders, id: \.self) { path in
                LabeledContent {
                    Button("移除", role: .destructive) { settings.watchFolders.removeAll { $0 == path } }
                } label: {
                    Text(path).textSelection(.enabled)
                }
            }
            Button("添加监视文件夹…", action: addFolder)
            Toggle("自动开始下载", isOn: $settings.watchAutoStart)
            Text("关闭时先打开新建下载面板，确认后再添加。")
                .foregroundStyle(.secondary)
            if let issue = model.bitTorrent?.watchFolders.lastError {
                Text(issue).foregroundStyle(Theme.wait)
                Button("重新扫描") { model.bitTorrent?.watchFolders.retry() }
            }
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let path = url.standardizedFileURL.path
            if !settings.watchFolders.contains(path) { settings.watchFolders.append(path) }
        }
    }
}
