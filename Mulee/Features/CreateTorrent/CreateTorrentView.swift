import AppKit
import MuleeCore
import SwiftUI
import UniformTypeIdentifiers

struct CreateTorrentView: View {
    let app: AppModel
    let engine: TorrentEngine
    let close: () -> Void
    let model: CreateTorrentModel
    let parentWindow: () -> NSWindow?

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            Text("制作种子").font(.headline)
            Form {
                LabeledContent("文件或文件夹") {
                    VStack(alignment: .trailing, spacing: 8) {
                        if let source = model.source { Text(source.path).textSelection(.enabled) }
                        Button("选择文件或文件夹…", action: chooseSource)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("节点服务器地址，每行一个")
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $model.trackerText)
                            .font(.body.monospaced())
                            .scrollContentBackground(.hidden)
                            .padding(4)
                            .accessibilityLabel("节点服务器地址，每行一个")
                            .accessibilityHint("输入节点服务器地址，每行一个；留空则不添加。")
                        if model.trackerText.isEmpty {
                            Text("输入节点服务器地址，每行一个；留空则不添加。")
                                .foregroundStyle(.secondary)
                                .padding(8)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(minHeight: 112)
                    .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor))
                    }
                }
                Toggle("私有种子", isOn: $model.isPrivate)
                LabeledContent("种子格式") { Text("v1+v2 混合") }
                LabeledContent("分块大小") { Text("自动") }
                Toggle("制作完成后立即开始做种", isOn: $model.startsSeeding)
            }
            .formStyle(.grouped)
            .disabled(model.isWorking)
            if let validation = model.validation { Text(validation).foregroundStyle(.secondary) }
            if model.isWorking {
                ProgressView(value: model.progress?.fractionCompleted ?? 0) {
                    Text("正在计算文件校验值，文件较大时需要几分钟")
                } currentValueLabel: {
                    HStack {
                        Text((model.progress?.fractionCompleted ?? 0).formatted(.percent.precision(.fractionLength(0))))
                        Spacer()
                        Text("已处理 \((model.progress?.processedBytes ?? 0).formatted(.byteCount(style: .file))) / \((model.progress?.totalBytes ?? 0).formatted(.byteCount(style: .file)))")
                    }
                    .monospacedDigit()
                }
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
        guard let window = parentWindow() else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { response in
            DispatchQueue.main.async { [weak window] in window?.makeKeyAndOrderFront(nil) }
            if response == .OK { model.source = panel.url }
        }
    }

    private func create() {
        guard let source = model.source, let window = parentWindow() else { return }
        let panel = Self.makeSavePanel(for: source)
        panel.beginSheetModal(for: window) { response in
            DispatchQueue.main.async { [weak window] in window?.makeKeyAndOrderFront(nil) }
            guard response == .OK, let output = panel.url else { return }
            let destination = output.pathExtension.lowercased() == "torrent"
                ? output : output.appendingPathExtension("torrent")
            start(to: destination)
        }
    }

    static func makeSavePanel(for source: URL) -> NSSavePanel {
        let panel = NSSavePanel()
        // 先限定类型再填文件名，避免保存面板按源文件扩展名重写默认名。
        panel.allowedContentTypes = [UTType(importedAs: "org.bittorrent.torrent", conformingTo: .data)]
        panel.allowsOtherFileTypes = false
        panel.canSelectHiddenExtension = false
        panel.isExtensionHidden = false
        panel.directoryURL = source.deletingLastPathComponent()
        panel.nameFieldStringValue = source.lastPathComponent + ".torrent"
        return panel
    }

    private func start(to output: URL) {
        model.start(to: output) { source, temporaryOutput, isPrivate, trackers, progress in
            _ = try await engine.createTorrent(
                from: source, to: temporaryOutput, isPrivate: isPrivate, trackers: trackers, progress: progress
            )
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
