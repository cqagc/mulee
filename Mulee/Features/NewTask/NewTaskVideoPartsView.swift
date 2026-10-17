import MuleeCore
import SwiftUI

struct NewTaskVideoPartsView: View {
    @Bindable var item: NewTaskLinkModel
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if item.isLoadingVideoParts {
                ProgressView("正在获取视频列表…")
                    .controlSize(.small)
            }
            if let error = item.videoPartsError {
                Text(error)
                    .foregroundStyle(.secondary)
                Button("重试", action: retry)
                    .disabled(item.isLoadingVideoParts)
            }
            if item.showsVideoPartsSelection {
                HStack {
                    Text(item.link.playlistID == nil ? String(localized: "分 P / 合集") : String(localized: "播放列表"))
                    Spacer()
                    Button("全选", action: selectAll)
                    Button("全不选", action: deselectAll)
                }
                ForEach(item.videoParts) { part in
                    Toggle(isOn: selection(for: part)) {
                        HStack {
                            Text(part.displayTitle)
                                .lineLimit(2)
                                .help(part.displayTitle)
                            Spacer()
                            if let duration = part.durationDescription {
                                Text(duration)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                if item.selectedVideoEntries.isEmpty {
                    Text("请至少选择一集")
                        .foregroundStyle(.secondary)
                }
                if item.showsPlaylistSubfolder {
                    Toggle("放进以列表名命名的子文件夹", isOn: $item.playlistSubfolder)
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
