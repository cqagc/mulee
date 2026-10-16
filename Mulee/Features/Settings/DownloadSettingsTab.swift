import SwiftUI

/// 设置·下载。
struct DownloadSettingsTab: View {
    @Environment(SettingsModel.self) private var model
    @State private var isChoosingFolder = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                LabeledContent("默认保存目录") {
                    HStack {
                        Text(model.saveDirectory)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("选择…") {
                            isChoosingFolder = true
                        }
                    }
                }
                Stepper(
                    String(localized: "同时进行的任务数：\(model.maxConcurrentTasks)"),
                    value: $model.maxConcurrentTasks,
                    in: SettingsModel.maxConcurrentTasksRange
                )
                Text("所有引擎合计；电驴等待来源和 BT 做种不占名额")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("HTTP 每任务线程数", selection: $model.httpThreads) {
                    ForEach(SettingsModel.httpThreadOptions, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
            }
            Section("磁盘保护") {
                Toggle("保留磁盘可用空间", isOn: $model.diskReserveEnabled)
                Stepper("保护容量：\(model.diskReserveGB) GB", value: $model.diskReserveGB, in: 1...500)
                    .disabled(!model.diskReserveEnabled)
                Text("达到保护容量时暂停该磁盘的下载；空间恢复到保护容量以上 1 GB 后，只恢复因磁盘空间暂停的任务。解压前也会检查。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder], onCompletion: folderChosen)
    }

    private func folderChosen(_ result: Result<URL, any Error>) {
        if case .success(let url) = result {
            model.saveDirectory = url.path(percentEncoded: false)
        }
    }
}

#Preview {
    DownloadSettingsTab()
        .environment(SettingsModel())
}
