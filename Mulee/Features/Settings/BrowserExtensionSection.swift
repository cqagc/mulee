import AppKit
import SafariServices
import SwiftUI

/// Browser installation remains an explicit user action.
struct BrowserExtensionSection: View {
    @State private var safariEnabled: Bool?
    @State private var safariReadError: String?
    @State private var refreshID = 0
    @State private var issue: String?
    @State private var showsChromeInstructions = false
    private static let identifier = "com.cqagc.mulee.safari-extension"
    private let readSafariEnabled: () async throws -> Bool
    private let refreshInterval: Duration

    init(readSafariEnabled: @escaping () async throws -> Bool = {
        try await SFSafariExtensionManager.stateOfSafariExtension(withIdentifier: Self.identifier).isEnabled
    }, refreshInterval: Duration = .seconds(2)) {
        self.readSafariEnabled = readSafariEnabled
        self.refreshInterval = refreshInterval
    }

    private var safariStatus: String {
        if let safariEnabled { return safariEnabled ? String(localized: "已启用") : String(localized: "未启用") }
        return safariReadError == nil ? String(localized: "正在读取…") : String(localized: "暂时无法读取")
    }

    var body: some View {
        Section("浏览器扩展") {
            LabeledContent("Safari", value: safariStatus)
            LabeledContent("扩展版本", value: "1.1.0")
            Button(action: openSafariPreferences) {
                if safariEnabled == true { Text("打开 Safari 扩展设置") }
                else { Text("在 Safari 中启用") }
            }
            Button("安装 Chrome 扩展…", action: revealChromeExtension)
            Text("只把你点选的链接交给本机 Mulee，在新建下载面板确认后开始下载。")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("网站登录状态默认不读取。仅在扩展弹窗中允许当前网站后，通过原生通道交接；Cookie 不进入链接或任务历史。")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let issue = issue ?? safariReadError {
                Text(issue)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .task(id: refreshID) {
            // SafariServices 只提供查询接口。在本视图显示期间串行复查，离开即取消。
            while !Task.isCancelled {
                await refreshSafariState()
                do { try await Task.sleep(for: refreshInterval) } catch { return }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshID &+= 1
        }
        .alert("安装 Chrome 扩展", isPresented: $showsChromeInstructions) {
            Button("好", role: .cancel) {}
        } message: {
            Text("已在访达中显示扩展目录。请先把 chrome 文件夹复制到固定位置，再打开 chrome://extensions，启用「开发者模式」，点「加载已解压的扩展程序」，选择复制后的 chrome 文件夹。首次交接时选择「打开 Mulee」，可勾选「始终允许」。要传递 B 站 / YouTube 登录状态，还需在 设置·视频 里允许。")
        }
    }

    private func refreshSafariState() async {
        do {
            let enabled = try await readSafariEnabled()
            guard !Task.isCancelled else { return }
            if safariEnabled != enabled { safariEnabled = enabled }
            if safariReadError != nil { safariReadError = nil }
        } catch {
            guard !Task.isCancelled else { return }
            if safariEnabled != nil { safariEnabled = nil }
            if safariReadError != error.localizedDescription { safariReadError = error.localizedDescription }
        }
    }

    private func openSafariPreferences() {
        Task {
            do {
                issue = nil
                try await SFSafariApplication.showPreferencesForExtension(withIdentifier: Self.identifier)
            } catch {
                issue = error.localizedDescription
            }
        }
    }

    private func revealChromeExtension() {
        guard let resources = Bundle.main.resourceURL else { return }
        let directory = resources.appending(path: "BrowserExtensions/chrome", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            issue = String(localized: "此构建未包含 Chrome 扩展。")
            return
        }
        issue = nil
        NSWorkspace.shared.activateFileViewerSelecting([directory])
        showsChromeInstructions = true
    }
}

/// 首次启动和「关于」共用设置中的安装操作。
struct BrowserExtensionGuide: View {
    let done: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                BrowserExtensionSection()
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("完成", action: done)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(width: 470, height: 420)
    }
}
