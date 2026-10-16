import AppKit
import MuleeCore
import SwiftUI

struct CreateTorrentView: View {
    let app: AppModel
    let engine: TorrentEngine
    let close: () -> Void
    let model: CreateTorrentModel

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            Text("制作种子").font(.headline)
            Form {
                LabeledContent("文件或文件夹") {
                    VStack(alignment: .trailing, spacing: 6) {
                        if let source = model.source { Text(source.path).textSelection(.enabled) }
                        Button("选择文件或文件夹…", action: chooseSource)
                    }
                }
                Text("节点服务器地址，每行一个")
                TextEditor(text: $model.trackerText)
                    .font(.body.monospaced())
                    .frame(minHeight: 100)
                    .accessibilityLabel("节点服务器地址，每行一个")
                Toggle("私有种子", isOn: $model.isPrivate)
                LabeledContent("种子格式", value: "v1+v2 混合")
                LabeledContent("分块大小", value: String(localized: "自动"))
                Toggle("制作完成后立即开始做种", isOn: $model.startsSeeding)
            }
            .disabled(model.isWorking)
            if let validation = model.validation { Text(validation).foregroundStyle(.secondary) }
            if model.isWorking {
                ProgressView("正在计算文件校验值，文件较大时需要几分钟")
            }
            if let issue = model.issue { Text(issue).foregroundStyle(Theme.wait) }
            if let output = model.output {
                Text("种子已保存。")
                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([output]) }
            }
            HStack {
                Spacer()
                Button(model.isWorking ? String(localized: "取消") : String(localized: "关闭")) {
                    model.cancel()
                    close()
                }
                .keyboardShortcut(.cancelAction)
                Button("制作…", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.source == nil || model.validation != nil || model.isWorking)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onDisappear { model.cancel() }
    }

    private func chooseSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { model.source = panel.url }
    }

    private func create() {
        guard let source = model.source else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = source.lastPathComponent + ".torrent"
        guard panel.runModal() == .OK, let output = panel.url else { return }
        model.start(to: output) { source, temporaryOutput, isPrivate, trackers in
            _ = try await engine.createTorrent(from: source, to: temporaryOutput, isPrivate: isPrivate, trackers: trackers)
        } seed: { torrent, directory in
            guard let coordinator = app.coordinator else { throw EngineError.notRunning }
            let draft = NewTaskModel(inputText: torrent.absoluteString, saveDirectory: directory, autoExtract: false)
            guard draft.canStartDownload else { throw EngineError.unsupportedLink }
            let previous = Set(app.tasks.map(\.id))
            await coordinator.add(links: draft.downloadLinks, autoExtract: false, directory: directory)
            guard let task = app.tasks.first(where: { !previous.contains($0.id) && $0.sourceLink == torrent.absoluteString }),
                  task.engineTaskID != nil, task.status != .failed else { throw EngineError.notRunning }
        }
    }
}
