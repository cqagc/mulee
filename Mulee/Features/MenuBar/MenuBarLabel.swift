import SwiftUI

/// 菜单栏上常驻的图标；有下载速度时右侧跟实时速度。
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.totalDownloadRate > 0 {
            Label {
                Text(model.totalDownloadRate, format: .byteCount(style: .file))
            } icon: {
                Image(.menuBarIcon)
            }
            .labelStyle(.titleAndIcon)
        } else {
            Label {
                Text("Mulee")
            } icon: {
                Image(.menuBarIcon)
            }
            .labelStyle(.iconOnly)
        }
    }
}
