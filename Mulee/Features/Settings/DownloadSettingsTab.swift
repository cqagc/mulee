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
                Picker("HTTP 每任务线程数", selection: $model.httpThreads) {
                    ForEach(SettingsModel.httpThreadOptions, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
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
