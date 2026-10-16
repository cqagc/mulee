import MuleeCore
import SwiftUI

struct HTTPTaskActionsView: View {
    @Environment(AppModel.self) private var model
    let task: DownloadTask
    @State private var replacement = ""
    @State private var message: String?
    @State private var isWorking = false
    @State private var needsRestartConfirmation = false
    @State private var checkedURL: URL?
    @State private var checkedContext: DownloadRequestContext?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("换个链接继续")
                .font(.subheadline.weight(.semibold))
            TextField("粘贴新的下载链接", text: $replacement)
                .textFieldStyle(.roundedBorder)
                .disabled(isWorking)
            Button(isWorking ? "正在检查文件…" : "检查并继续") {
                guard let url = URL(string: replacement.trimmingCharacters(in: .whitespacesAndNewlines)),
                      ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
                      url.user == nil, url.password == nil else {
                    message = "请输入有效的 HTTP 或 HTTPS 下载链接。"
                    return
                }
                checkedURL = url
                checkedContext = nil
                replace(url, restart: false)
            }
            .disabled(isWorking || replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.coordinator == nil)
            Button("从浏览器抓取新链接") {
                model.waitForBrowserHTTPReplacement(task.id)
                message = "在浏览器里重新点下载，Mulee 会接住新链接。等待五分钟内同网站或同文件名的链接。"
            }
            .disabled(isWorking || model.coordinator == nil)
            if model.waitingHTTPReplacement?.taskID == task.id {
                Button("取消等待") { model.waitingHTTPReplacement = nil }
            }
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: model.pendingBrowserHTTPReplacement?.id) {
            guard let incoming = model.pendingBrowserHTTPReplacement, incoming.taskID == task.id else { return }
            model.pendingBrowserHTTPReplacement = nil
            checkedURL = incoming.url
            checkedContext = incoming.context
            replacement = incoming.url.absoluteString
            replace(incoming.url, restart: false)
        }
        .alert("文件不同或无法确认，是否从头下载？", isPresented: $needsRestartConfirmation) {
            Button("从头下载", role: .destructive) {
                if let checkedURL { replace(checkedURL, restart: true) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("原来的下载进度将被清除，已有文件会移到废纸篓。")
        }
    }

    private func replace(_ url: URL, restart: Bool) {
        guard let coordinator = model.coordinator else { return }
        isWorking = true
        message = nil
        Task {
            defer { isWorking = false }
            do {
                try await coordinator.replaceHTTPLink(task.id, newURL: url, restartFromScratch: restart, requestContext: checkedContext)
                replacement = ""
                message = "链接已更新，任务将继续下载。"
            } catch let failure as HTTPDownloadFailure where failure == .resourceChanged || failure == .unknownIdentity {
                message = failure.localizedDescription
                needsRestartConfirmation = true
            } catch {
                message = EngineStatusPresentation.errorMessage(error)
            }
        }
    }
}
