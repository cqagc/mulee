import AppKit
import UniformTypeIdentifiers
import MuleeCore
import SwiftUI

/// 由主窗口作为 sheet 呈现的新建下载面板。
struct NewTaskSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(SettingsModel.self) private var settings
    @Environment(\.dismiss) private var dismiss
    private let suppliedDraft: NewTaskModel?
    @State private var addingTask: Task<Void, Never>?

    init(draft: NewTaskModel? = nil) {
        suppliedDraft = draft
    }

    private var draft: NewTaskModel { suppliedDraft ?? model.newTaskDraft }

    private func recognitionMessage(_ row: SmartPasteParser.Row) -> String {
        if row.isInfoHash { return String(localized: "已识别为磁力链接") }
        if row.isTorrentFile { return String(localized: "已识别种子文件") }
        return row.message
    }

    var body: some View {
        @Bindable var draft = draft

        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("新建下载")
                    .font(.headline)
                Text("粘贴一个或多个链接，类型会自动识别。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)

            TextField("粘贴下载链接，每行一个", text: $draft.inputText, axis: .vertical)
                .font(.callout.monospaced())
                .lineLimit(3...6)
                .onExitCommand(perform: cancel)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.background, in: .rect(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.quaternary)
                }
                .padding(.horizontal, 22)
                .padding(.top, 14)

            Button("打开种子或 Metalink 文件…", action: openTorrentFiles)
                .padding(.horizontal, 22)
                .padding(.top, 10)

            Text("识别到 \(draft.linkCount) 个链接")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 22)
                .padding(.top, 16)
                .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(draft.inputRows, id: \.line) { row in
                        Text("第 \(row.line) 行：\(recognitionMessage(row))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                if draft.links.isEmpty {
                    ContentUnavailableView("等待粘贴链接", systemImage: MuleeSymbol.add.name)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(draft.links) { item in
                            if item.id != draft.links.first?.id {
                                Divider()
                            }
                            NewTaskLinkRow(item: item) {
                                await draft.mergeTrackers(for: item, in: model)
                            }
                        }
                    }
                }
            }
            .frame(height: 360)
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.quaternary)
            }
            .clipShape(.rect(cornerRadius: 10))
            .padding(.horizontal, 22)
            .padding(.bottom, 18)

            Divider()
            NewTaskFooterView(draft: draft, cancel: cancel, startDownload: startDownload)
        }
        .frame(width: 640)
        .onKeyPress(.escape) {
            if let editor = NSApp.currentEvent?.window?.firstResponder as? NSTextView, editor.hasMarkedText() {
                return .ignored
            }
            cancel()
            return .handled
        }
        .disabled(draft.isChecking)
        .onDisappear { addingTask?.cancel() }
        .onChange(of: draft.knownDownloadBytes, initial: true) { refreshDiskCheck() }
        .onChange(of: draft.saveDirectory) { refreshDiskCheck() }
        .onChange(of: draft.parsedLinks, initial: true) {
            for item in draft.links {
                item.applyJunkFilter(BitTorrentEngineConfiguration.configuration(from: settings))
            }
        }
        .task(id: draft.parsedLinks) {
            draft.refreshDuplicateWarnings(in: model)
            await draft.resolveDuplicateMetadata(in: model)
        }
        .modifier(NewTaskDropReceiver(showsHint: true))
        .onAppear(perform: prepareDraft)
        .onChange(of: model.pendingNewTaskText) {
            prepareDraft()
        }
    }

    private func openTorrentFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["torrent", "metalink", "meta4"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = String(localized: "打开下载文件")
        if panel.runModal() == .OK {
            draft.appendTorrentFiles(panel.urls)
        }
    }

    private func prepareDraft() {
        if let suppliedDraft {
            suppliedDraft.consumePendingText(from: model)
        } else {
            // onChange 即使先于 onAppear，也会准备并复用应用持有的草稿。
            model.prepareNewTaskDraft(settings: settings)
        }
    }

    private func cancel() {
        model.finishNewTask()
        dismiss()
    }

    private func refreshDiskCheck() {
        _ = draft.checkDisk { size, directory in
            guard size > 0, let protection = model.diskReserveMonitor else { return false }
            return try protection.requiresConfirmation(forKnownBytes: size, in: directory)
        }
    }

    private func startDownload() {
        guard draft.canStartDownload else { return }
        addingTask = Task { @MainActor in
            guard await draft.checkBeforeAdding(in: model, settings: settings), !Task.isCancelled else { return }
            draft.createTasks(in: model)
            model.finishNewTask()
            dismiss()
        }
    }
}

#if DEBUG
#Preview("四种链接") {
    NewTaskSheet(draft: NewTaskModel(inputText: NewTaskPreviewData.inputText, parser: { _ in
        NewTaskPreviewData.links
    }, metadataProvider: ExampleTorrentMetadataProvider()))
    .environment(AppModel(tasks: MockData.tasks))
    .environment(SettingsModel())
}

#Preview("等待粘贴") {
    NewTaskSheet()
        .environment(AppModel(tasks: MockData.tasks))
        .environment(SettingsModel())
}
#endif
