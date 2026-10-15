import SwiftUI

/// 菜单栏上常驻的图标 + 实时下载速度。
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Label {
            Text(model.totalDownloadRate, format: .byteCount(style: .file))
        } icon: {
            Image(.menuBarIcon)
        }
        .labelStyle(.titleAndIcon)
    }
}
