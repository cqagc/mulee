import SwiftUI

/// 主窗口与菜单栏共用文字，颜色之外也明确说明暂停状态。
struct DiskReserveBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ForEach(model.diskReserveWarnings) { warning in
            VStack(alignment: .leading, spacing: 4) {
                Label(warning.isPaused ? String(localized: "因磁盘空间不足已暂停") : String(localized: "磁盘空间快到保护线"),
                      systemImage: MuleeSymbol.statusFailed.name)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.wait)
                Text("\(warning.volume.lastPathComponent)：剩余 \(TaskPresentation.bytes(warning.available))，保护容量 \(TaskPresentation.bytes(warning.reserve))。")
                Text(warning.isPaused ? String(localized: "该磁盘的下载已暂停。清理磁盘、换保存目录或调低保护容量后继续。")
                     : String(localized: "下载仍在继续。请清理磁盘、换保存目录或调低保护容量。"))
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .accessibilityElement(children: .combine)
        }
    }
}
