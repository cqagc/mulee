import SwiftUI

/// 本地种子的真实文件选择；元数据未到时明确说明后续入口。
struct NewTaskTorrentFilesView: View {
    @Bindable var item: NewTaskLinkModel

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 6) {
            if let files = Binding($item.files) {
                let selectedCount = item.files?.filter(\.isSelected).count ?? 0
                ForEach(files) { $file in
                    HStack(spacing: 9) {
                        Toggle(file.name, isOn: $file.isSelected)
                            .toggleStyle(.checkbox)
                            .disabled(file.isSelected && selectedCount <= 1)
                            .lineLimit(1)
                            .help(file.name)
                        Spacer(minLength: 8)
                        Text(file.size, format: .byteCount(style: .file))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            } else {
                Text(item.metadataError ?? String(localized: "开始后可在详情里选择要下载的文件"))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.vertical, 10)
        .padding(.leading, 68)
        .padding(.trailing, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5))
    }
}
