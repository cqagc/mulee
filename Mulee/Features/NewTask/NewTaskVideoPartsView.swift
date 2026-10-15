import MuleeCore
import SwiftUI

struct NewTaskVideoPartsView: View {
    @Bindable var item: NewTaskLinkModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if item.isLoadingVideoParts {
                ProgressView("正在获取视频列表…")
                    .controlSize(.small)
            }
            if let error = item.videoPartsError {
                Text(error)
                    .foregroundStyle(.secondary)
            }
            if item.videoParts.count > 1 {
                HStack {
                    Text("分 P / 合集")
                    Spacer()
                    Button("全选", action: selectAll)
                    Button("全不选", action: deselectAll)
                }
                ForEach(item.videoParts) { part in
                    Toggle(isOn: selection(for: part)) {
                        Text("P\(part.index) \(part.title)")
                            .lineLimit(2)
                            .help(part.title)
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
        .font(.caption)
        .padding(.bottom, 12)
        .accessibilityElement(children: .contain)
    }

    private func selection(for part: YtDlpPlaylistEntry) -> Binding<Bool> {
        Binding(
            get: { item.selectedVideoParts.contains(part.id) },
            set: { selected in
                if selected { item.selectedVideoParts.insert(part.id) }
                else { item.selectedVideoParts.remove(part.id) }
            }
        )
    }

    private func selectAll() {
        item.selectedVideoParts = Set(item.videoParts.map(\.id))
    }

    private func deselectAll() {
        item.selectedVideoParts = []
    }
}
