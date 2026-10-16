import AppKit
import SwiftUI

struct BitTorrentBlocklistSettingsSection: View {
    @Environment(SettingsModel.self) private var settings
    @Environment(AppModel.self) private var model
    @State private var result: String?
    @State private var isImporting = false

    var body: some View {
        Section("IP 黑名单") {
            Text("导入 P2P 或 DAT 文件后，会断开并阻止列表中的地址，保留手动封禁的 IP。")
                .foregroundStyle(.secondary)
            if !settings.ipBlocklistPath.isEmpty {
                Text(URL(filePath: settings.ipBlocklistPath).lastPathComponent)
            }
            Button("导入 IP 黑名单…", action: importFile)
                .disabled(isImporting || model.bitTorrent == nil)
            if isImporting { ProgressView("正在导入") }
            if let result { Text(result).textSelection(.enabled) }
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
