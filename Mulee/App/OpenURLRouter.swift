import AppKit
import MuleeCore
import OSLog

/// 统一处理冷启动和运行中的系统打开事件。
final class OpenURLRouter {
    private let model: AppModel
    private let settings: SettingsModel

    init(model: AppModel, settings: SettingsModel) {
        self.model = model
        self.settings = settings
    }

    /// 从服务菜单接收选中文本，沿用浏览器入口的远程链接和数量限制。
    @discardableResult
    func openSelectedText(_ text: String) -> Bool {
        guard text.utf8.count <= OpenURLRequest.maximumBytes else { return false }
        let links = LinkParser.parse(text)
        guard !links.isEmpty, links.count <= OpenURLRequest.maximumLinks,
              links.allSatisfy(OpenURLRequest.isRemote) else { return false }
        var components = URLComponents()
        components.scheme = "mulee"
        components.host = "add"
        components.queryItems = links.map { URLQueryItem(name: "url", value: $0.original) }
        guard let url = components.url else { return false }
        return open([url])
    }

    @discardableResult
    func open(_ urls: [URL]) -> Bool {
        let requests = urls.compactMap { OpenURLRequest.parse($0, detectPagePassword: settings.detectPagePassword) }
        guard !requests.isEmpty else {
            model.openURLIssue = String(localized: "链接无效、超出限制，或包含不允许的本地文件。")
            return false
        }
        for request in requests {
            for link in request.links {
                model.pendingNewTaskContexts[link] = NewTaskContext(
                    sourcePageURL: request.sourcePageURL, password: request.password
                )
            }
        }
        let text = requests.flatMap(\.links).map(\.original).joined(separator: "\n")
        model.showNewTask(prefill: text)
        NSApp?.activate()
        #if DEBUG
        Logger(subsystem: "com.cqagc.mulee", category: "OpenURL").debug(
            "预填链接数：\(requests.flatMap(\.links).count)，待确认；已有任务数：\(self.model.tasks.count)"
        )
        if UserDefaults.standard.bool(forKey: "MuleeOpenURLDiagnostics") {
            // 显式调试开关下输出预填文本，绝不输出页面文字或密码。
            FileHandle.standardOutput.write(Data("Mulee OpenURL prefill: \(text)\n".utf8))
        }
        #endif
        return true
    }
}
