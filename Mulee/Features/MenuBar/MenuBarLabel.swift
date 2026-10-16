import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 菜单栏上常驻的图标；有下载速度时右侧跟实时速度。
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            label
        }
        .modifier(NewTaskDropReceiver())
    }

    @ViewBuilder
    private var label: some View {
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

/// 拖放只预填草稿；与菜单栏粘贴框的直接下载行为分开。
struct NewTaskDropReceiver: ViewModifier {
    @Environment(AppModel.self) private var model

    var showsHint = false
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content.onDrop(of: OpenURLDropHandler.types, isTargeted: $isTargeted) { providers in
            OpenURLDropHandler.accept(providers, model: model)
        }
        .overlay {
            if showsHint && isTargeted { NewTaskDropHint() }
        }
    }
}
