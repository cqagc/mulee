import MuleeCore
import SwiftUI

struct TaskChecksumView: View {
    @Environment(AppModel.self) private var model
    let task: DownloadTask
    @State private var input = ""
    @State private var message: String?
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("下载校验")
                .font(.subheadline.weight(.semibold))
            TextField("MD5 / SHA-1 / SHA-256", text: $input)
                .textFieldStyle(.roundedBorder)
            Button("保存校验值") { save() }
                .disabled(isWorking || model.coordinator == nil)
            if let result = task.checksumVerification {
                Text(result.matches == true ? String(localized: "校验通过") : result.matches == false ? String(localized: "校验值不一致，请重新下载。") : result.errorMessage ?? String(localized: "等待校验"))
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                if result.matches == false {
                    Button("重新下载") { redownload() }
                        .disabled(isWorking || model.coordinator == nil)
                }
            } else if task.checksum != nil {
                Text([.completed, .seeding].contains(task.status) ? "正在校验文件…" : "已设置校验值，下载完成后显示结果。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: task.id) {
            input = task.checksum?.aria2Value ?? ""
            message = nil
        }
        .onChange(of: task.checksum) { _, checksum in
            if !isWorking { input = checksum?.aria2Value ?? "" }
        }
    }

    private func save() {
        guard let coordinator = model.coordinator else { return }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let checksum = DownloadChecksum.parse(text)
        guard text.isEmpty || checksum != nil else {
            message = String(localized: "校验值格式无效，请粘贴完整的 MD5、SHA-1 或 SHA-256。")
            return
        }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await coordinator.setChecksum(task.id, checksum: checksum)
                message = text.isEmpty ? String(localized: "已清除手动校验值。") : String(localized: "校验值已保存。")
            } catch {
                message = EngineStatusPresentation.errorMessage(error)
            }
        }
    }

    private func redownload() {
        if task.kind != .http {
            if let link = LinkParser.parse(task.sourceLink).first {
                model.pendingNewTaskContexts[link] = NewTaskContext(
                    sourcePageURL: task.sourcePageURL, requestContext: task.requestContext ?? .init(), checksum: task.checksum
                )
            }
            model.showNewTask(prefill: task.sourceLink)
            return
        }
        guard let coordinator = model.coordinator, let url = URL(string: task.sourceLink) else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await coordinator.replaceHTTPLink(task.id, newURL: url, restartFromScratch: true)
            } catch {
                message = EngineStatusPresentation.errorMessage(error)
            }
        }
    }
}
