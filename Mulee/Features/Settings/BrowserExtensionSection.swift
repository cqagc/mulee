import AppKit
import SafariServices
import SwiftUI

/// Browser installation remains an explicit user action.
struct BrowserExtensionSection: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var safariStatus = "正在读取…"
    @State private var issue: String?
    @State private var showsChromeInstructions = false
    private let identifier = "com.cqagc.mulee.safari-extension"

    var body: some View {
        Section("浏览器扩展") {
            LabeledContent("Safari", value: safariStatus)
            Button("在 Safari 中启用", action: openSafariPreferences)
            Button("安装 Chrome 扩展…", action: revealChromeExtension)
            Text("只把你点选的链接交给本机 Mulee，在新建下载面板确认后开始下载。")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let issue {
                Text(issue)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .task { await refreshSafariState() }
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                Task { await refreshSafariState() }
            }
        }
        .alert("安装 Chrome 扩展", isPresented: $showsChromeInstructions) {
            Button("好", role: .cancel) {}
        } message: {
            Text("已在访达中显示扩展目录。请先把 chrome 文件夹复制到固定位置，再打开 chrome://extensions，启用「开发者模式」，点「加载已解压的扩展程序」，选择复制后的 chrome 文件夹。首次交接时选择「打开 Mulee」，可勾选「始终允许」。要传递 B 站 / YouTube 登录状态，还需在 设置·视频 里允许。")
        }
    }

    private func refreshSafariState() async {
        do {
            let state = try await SFSafariExtensionManager.stateOfSafariExtension(withIdentifier: identifier)
            safariStatus = state.isEnabled ? "已启用" : "未启用"
            issue = nil
        } catch {
            safariStatus = "暂时无法读取"
            issue = error.localizedDescription
        }
    }

    private func openSafariPreferences() {
        Task {
            do {
                try await SFSafariApplication.showPreferencesForExtension(withIdentifier: identifier)
                await refreshSafariState()
            } catch {
                issue = error.localizedDescription
            }
        }
    }

    private func revealChromeExtension() {
        guard let resources = Bundle.main.resourceURL else { return }
        let directory = resources.appending(path: "BrowserExtensions/chrome", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            issue = "此构建未包含 Chrome 扩展。"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([directory])
        showsChromeInstructions = true
    }
}
