import SwiftUI

/// 示例元数据沿用原型的浅色文件选择底板。
struct NewTaskTorrentFilesView: View {
    @Bindable var item: NewTaskLinkModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let files = Binding($item.files) {
                ForEach(files) { $file in
                    HStack(spacing: 9) {
                        Toggle(file.name, isOn: $file.isSelected)
                            .toggleStyle(.checkbox)
                            .lineLimit(1)
                            .help(file.name)
                        Spacer(minLength: 8)
                        Text(file.size, format: .byteCount(style: .file))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            } else {
                Text("正在获取文件列表…")
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
