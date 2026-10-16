import SwiftUI

struct NewTaskLinkRow: View {
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
            NewTaskChecksumView(item: item)
        }
    }

}
