import SwiftUI
import UniformTypeIdentifiers

struct NewTaskFooterView: View {
    @Bindable var draft: NewTaskModel
    let cancel: () -> Void
    let startDownload: () -> Void

    @State private var isChoosingDirectory = false
    @State private var directoryError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("保存到")
                    .foregroundStyle(.secondary)
                Button(draft.saveDirectoryLabel, action: chooseDirectory)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(draft.saveDirectory.path)
                Spacer(minLength: 12)
                Toggle("完成后自动解压", isOn: $draft.autoExtract)
                    .toggleStyle(.checkbox)
            }
            .font(.caption)

            if let directoryError {
                Text(directoryError)
                    .font(.caption)
                    .foregroundStyle(Theme.wait)
            }

            HStack(spacing: 8) {
                Spacer()
                Button("取消", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("开始下载 \(draft.linkCount) 个任务", action: startDownload)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.canStartDownload)
            }

            if draft.hasVideoLinks {
                Text("安装浏览器扩展后可自动同步 B 站登录状态，下载高码率画质。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .fileImporter(
            isPresented: $isChoosingDirectory,
            allowedContentTypes: [.folder],
            onCompletion: selectDirectory
        )
    }

    private func chooseDirectory() {
        directoryError = nil
        isChoosingDirectory = true
    }

    private func selectDirectory(_ result: Result<URL, any Error>) {
        switch result {
        case .success(let url):
            draft.saveDirectory = url
            directoryError = nil
        case .failure(let error):
            directoryError = String(localized: "无法选择保存目录：\(error.localizedDescription)")
        }
    }
}
