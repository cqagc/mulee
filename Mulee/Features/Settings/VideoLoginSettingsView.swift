import MuleeCore
import SwiftUI

struct VideoLoginSettingsView: View {
    @State private var bilibiliUpdatedAt: Date?
    @State private var youtubeUpdatedAt: Date?
    @State private var issue: String?
    @State private var installed = false
    @State private var busy = false

    var body: some View {
        Section("浏览器登录状态") {
            VideoLoginStatusView(site: .bilibili, updatedAt: bilibiliUpdatedAt, clear: clearBilibili)
            VideoLoginStatusView(site: .youtube, updatedAt: youtubeUpdatedAt, clear: clearYouTube)
            Text("在浏览器扩展中开启登录状态传递后，Mulee 才会接收。登录状态优先保存在钥匙串，不支持时保存在仅你可读的本机文件。")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("安装 Chrome 登录状态连接", action: install)
                .disabled(busy)
            if installed {
                Text("Chrome 连接已安装")
                    .foregroundStyle(.secondary)
            }
            if let issue { Text(issue).foregroundStyle(.secondary) }
        }
        .task {
            while !Task.isCancelled {
                await refresh()
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }

    private func refresh() async {
        do {
            bilibiliUpdatedAt = try await VideoLoginStore.shared.updatedAt(for: .bilibili)
            youtubeUpdatedAt = try await VideoLoginStore.shared.updatedAt(for: .youtube)
        } catch {
            issue = String(localized: "无法读取浏览器登录状态")
        }
    }

    private func clearBilibili() { clear(.bilibili) }
    private func clearYouTube() { clear(.youtube) }

    private func clear(_ site: VideoSite) {
        Task {
            do {
                try await VideoLoginStore.shared.clear(site)
                issue = nil
                await refresh()
            } catch {
                issue = String(localized: "无法清除浏览器登录状态")
            }
        }
    }

    private func install() {
        busy = true
        defer { busy = false }
        do {
            guard let executable = Bundle.main.executableURL else { throw EngineError.binaryNotFound }
            try VideoNativeMessaging.install(executable: executable)
            installed = true
            issue = nil
        } catch {
            issue = String(localized: "无法安装 Chrome 登录状态连接")
        }
    }
}
