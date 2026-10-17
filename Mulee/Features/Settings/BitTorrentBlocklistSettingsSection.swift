import AppKit
import SwiftUI

struct BitTorrentBlocklistSettingsSection: View {
    @Environment(SettingsModel.self) private var settings
    @Environment(AppModel.self) private var model
    @State private var result: String?
    @State private var isImporting = false

    var body: some View {
        @Bindable var settings = settings
        Section("IP 黑名单") {
            Text("导入 P2P 或 DAT 文件后，会断开并阻止列表中的地址，保留手动封禁的 IP。")
                .foregroundStyle(.secondary)
            if !settings.ipBlocklistPath.isEmpty {
                Text(URL(filePath: settings.ipBlocklistPath).lastPathComponent)
            }
            TextField("黑名单网址", text: $settings.ipBlocklistURL)
            Text("每 7 天更新一次，支持 gzip；与本地名单合并，更新失败时保留旧名单。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let updater = model.bitTorrent?.blocklistUpdater {
                if let date = updater.lastUpdate {
                    LabeledContent("上次更新", value: date.formatted(date: .abbreviated, time: .shortened))
                }
                if let status = updater.result { Text(status).textSelection(.enabled) }
            }
            Button("导入 IP 黑名单…", action: importFile)
                .disabled(isImporting || model.bitTorrent == nil)
            if isImporting { ProgressView("正在导入") }
            if let result { Text(result).textSelection(.enabled) }
        }
        Section("原种子文件") {
            Toggle("添加成功后将原种子移到废纸篓", isOn: $settings.trashTorrentAfterAdd)
            Text("仅处理从访达打开或拖入的种子；监视文件夹仍移到 .mulee-added。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func importFile() {
        guard let engine = model.bitTorrent?.engine else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let file = panel.url else { return }
        isImporting = true
        Task {
            defer { isImporting = false }
            do {
                let imported = try await engine.importIPBlocklist(from: file)
                settings.ipBlocklistPath = file.path
                result = String(localized: "已导入 \(imported.blockedRanges) 条地址范围。")
            } catch {
                result = String(localized: "导入失败：\(EngineStatusPresentation.errorMessage(error))。请检查文件格式和访问权限后重试。")
            }
        }
    }
}
