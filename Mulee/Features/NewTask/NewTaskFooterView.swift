import MuleeCore
import SwiftUI
import UniformTypeIdentifiers

struct NewTaskFooterView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var draft: NewTaskModel
    let cancel: () -> Void
    let startDownload: () -> Void

    @State private var isChoosingDirectory = false
    @State private var directoryError: String?
    @State private var loggedInSites: Set<VideoSite> = []
    @State private var checkedLoginSites: Set<VideoSite> = []

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
                if draft.showsAutoExtract {
                    Toggle("完成后自动解压", isOn: $draft.autoExtract)
                        .toggleStyle(.checkbox)
                }
            }
            .font(.caption)

            if let directoryError {
                Text(directoryError)
                    .font(.caption)
                    .foregroundStyle(Theme.wait)
            }

            if let warning = draft.diskWarning {
                Text(warning)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("已了解磁盘空间风险，继续添加", isOn: $draft.diskConfirmed)
                    .toggleStyle(.checkbox)
            }
            if let note = draft.diskCheckNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if draft.needsDuplicateChoice {
                Picker("遇到同名文件", selection: $draft.duplicateChoice) {
                    Text("请选择处理方式").tag(DownloadRequestContext.DuplicateAction?.none)
                    Text("自动编号保留两份").tag(DownloadRequestContext.DuplicateAction?.some(.rename))
                    Text("覆盖已有文件").tag(DownloadRequestContext.DuplicateAction?.some(.overwrite))
                }
            }
            if draft.showsEngineDuplicateNote {
                Text("BT 与视频沿用引擎的同名处理。要保留独立副本，请选择其他保存目录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Spacer()
                Button("取消", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("开始下载 \(draft.downloadTaskCount) 个任务", action: startDownload)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.canStartDownload)
            }

            ForEach(draft.videoLoginHintSites(loggedInSites: loggedInSites), id: \.self) { site in
                if checkedLoginSites.contains(site) {
                    Text(site == .bilibili
                         ? String(localized: "下载 B 站大会员画质需要登录状态，可在浏览器扩展里开启『视频登录状态』")
                         : String(localized: "下载 YouTube 年龄限制或会员视频需要登录状态，可在浏览器扩展里开启『视频登录状态』"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .task(id: draft.videoLoginSites) {
            await refreshLoginStates()
        }
        .task(id: scenePhase) {
            if scenePhase == .active { await refreshLoginStates() }
        }
        .fileImporter(
            isPresented: $isChoosingDirectory,
            allowedContentTypes: [.folder],
            onCompletion: selectDirectory
        )
    }

    private func refreshLoginStates() async {
        for site in draft.videoLoginSites {
            let updatedAt = try? await VideoLoginStore.shared.updatedAt(for: site)
            guard !Task.isCancelled else { return }
            if updatedAt != nil {
                loggedInSites.insert(site)
            } else {
                loggedInSites.remove(site)
            }
            checkedLoginSites.insert(site)
        }
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
