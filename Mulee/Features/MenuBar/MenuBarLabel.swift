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

    func body(content: Content) -> some View {
        content.onDrop(of: [.fileURL, .url, .plainText], isTargeted: nil) { providers in
            let accepted = providers.filter { provider in
                provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                    || provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
                    || provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
            }
            guard !accepted.isEmpty else { return false }
            for provider in accepted {
                let type = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) ? UTType.fileURL
                    : provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) ? UTType.url : UTType.plainText
                provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { value, _ in
                    let text: String?
                    if let url = value as? URL {
                        text = NewTaskModel.droppedURLText(url)
                    } else if let data = value as? Data, let value = String(data: data, encoding: .utf8) {
                        text = NewTaskModel.droppedText(value)
                    } else if let value = value as? String {
                        text = NewTaskModel.droppedText(value)
                    } else {
                        text = nil
                    }
                    guard let text, !text.isEmpty else { return }
                    Task { @MainActor in model.showNewTask(prefill: text) }
                }
            }
            return true
        }
    }
}
