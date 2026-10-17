import MuleeCore
import SwiftUI

struct HTTPProxySettingsSection: View {
    @Environment(SettingsModel.self) private var settings
    @Environment(AppModel.self) private var model
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var message: String?
    @State private var isSaving = false
    @State private var actual = HTTPProxyConfiguration(mode: .off)

    var body: some View {
        @Bindable var settings = settings
        Section("HTTP 下载代理") {
            Picker("连接方式", selection: $settings.httpProxyMode) {
                Text("跟随系统").tag(HTTPProxyConfiguration.Mode.system)
                Text("直连").tag(HTTPProxyConfiguration.Mode.off)
                Text("手动设置").tag(HTTPProxyConfiguration.Mode.manual)
            }
            if settings.httpProxyMode == .manual {
                TextField("http://主机:端口", text: $address)
                TextField("代理账号（可选）", text: $username)
                SecureField("代理密码（可选）", text: $password)
                Button(isSaving ? "正在应用…" : "保存并应用") { save() }
                    .disabled(isSaving)
            }
            LabeledContent("当前 HTTP 连接", value: actual.description)
            if let reason = actual.unsupportedReason { Text(reason).foregroundStyle(.secondary) }
            Text("用于 HTTP 下载、视频下载和链接预检；BT 和电驴保持原来的连接方式。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .onAppear { address = settings.httpProxyURL }
        .task(id: settings.httpProxyMode) {
            await refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) }
                catch { return }
                await refresh()
            }
        }
    }

    private func refresh() async {
        do {
            try await model.coordinator?.refreshHTTPProxy()
            actual = HTTPProxyConfiguration(mode: settings.httpProxyMode, manualURL: settings.httpProxyURL)
            message = nil
        } catch { message = "代理设置未能应用，请稍后重新应用。" }
    }

    private func save() {
        guard let url = HTTPProxyConfiguration.manualURL(address), let host = url.host else {
            message = "请输入有效的 HTTP 代理地址，例如 http://proxy.example.org:8080。"
            return
        }
        // 口令不随地址进入 UserDefaults；地址里的登录信息也转存到钥匙串。
        let components = URLComponents(string: address)
        let credential = HTTPCredentialStore.Credential(
            username: username.isEmpty ? components?.user ?? "" : username,
            password: password.isEmpty ? components?.password ?? "" : password
        )
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await Task.detached {
                    if credential.username.isEmpty && credential.password.isEmpty {
                        try HTTPCredentialStore.delete(host: host, service: HTTPCredentialStore.proxyService)
                    } else {
                        try HTTPCredentialStore.save(credential, host: host, service: HTTPCredentialStore.proxyService)
                    }
                }.value
                settings.httpProxyURL = url.absoluteString
                address = url.absoluteString
                password = ""
                await refresh()
            } catch { message = "代理账号未能保存，原设置已保留；请解锁钥匙串后重试。" }
        }
    }
}
