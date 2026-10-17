import AppKit
import SwiftUI

struct NewTaskLinkRow: View {
    @Environment(AppModel.self) private var model
    @Environment(MainWindowState.self) private var windowState: MainWindowState?
    @Bindable var item: NewTaskLinkModel
    let mergeTrackers: () async -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Text(item.typeLabel)
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 42)
                    .padding(.vertical, 3)
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(.quaternary)
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .help(item.name)
                    Text(item.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(item.detail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(item.sizeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            if item.link.kind == .bittorrent {
                NewTaskTorrentFilesView(item: item)
            }
            if item.link.kind == .video {
                NewTaskVideoOptionsView(item: item)
            }
            if let message = item.duplicateMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Text(message)
                        .fixedSize(horizontal: false, vertical: true)
                    if item.canMergeTrackers && !item.duplicateAcknowledged {
                        Button("合并 tracker，保留已有任务") {
                            Task { await mergeTrackers() }
                        }
                        .disabled(item.isMergingTrackers)
                    }
                    Toggle("保留已有任务，跳过本次重复项", isOn: $item.duplicateAcknowledged)
                        .toggleStyle(.checkbox)
                }
                .font(.caption)
                .padding(12)
            }
            if let message = item.existingDownloadMessage {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: MuleeSymbol.info.name)
                        .accessibilityHidden(true)
                    Text(message)
                        .fixedSize(horizontal: false, vertical: true)
                    if item.link.kind == .video, let id = item.existingDownloadID {
                        Button("显示任务") { showTask(id) }
                    }
                    if item.link.kind == .http, let file = item.existingDownloadFile {
                        Button("在访达中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([file])
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 68)
                .padding(.trailing, 14)
                .padding(.vertical, 8)
            }
            // 种子通常包含多个文件，单个校验值只对 HTTP 下载有意义。
            if item.link.kind == .http {
                NewTaskChecksumView(item: item)
            }
        }
        .onChange(of: item.videoIdentity, initial: true) { item.refreshExistingDownload(in: model.tasks) }
        .onChange(of: item.selectedVideoParts) { item.refreshExistingDownload(in: model.tasks) }
        .onChange(of: model.tasks) { item.refreshExistingDownload(in: model.tasks) }
    }

    private func showTask(_ id: UUID) {
        guard model.tasks.contains(where: { $0.id == id && $0.deletedAt == nil }) else { return }
        windowState?.selection = .all
        windowState?.search = ""
        model.selectedTaskID = id
        model.isShowingNewTask = false
        model.mainWindowRequest += 1
    }

}
