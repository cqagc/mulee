import SwiftUI

struct NewTaskLinkRow: View {
    let item: NewTaskLinkModel

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
        }
    }
}
