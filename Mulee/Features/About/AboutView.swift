import AppKit
import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var licensesUnavailable = false

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text(verbatim: "Mulee")
                .font(.largeTitle.bold())
            Text(verbatim: AboutVersion.display(info: Bundle.main.infoDictionary ?? [:]))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("适用于 macOS 的开源下载工具。")
            if let url = URL(string: "https://www.cqagc.com") {
                Link("Made by CQAGC", destination: url)
            }
            HStack(spacing: 20) {
                if let url = URL(string: "https://github.com/cqagc/mulee") {
                    Link("GitHub", destination: url)
                }
                if let url = URL(string: "https://github.com/cqagc/mulee/blob/main/LICENSE") {
                    Link("GPL-3.0 许可证", destination: url)
                }
            }
            Button("第三方许可证", action: showLicenses)
            if licensesUnavailable {
                Text("此构建未包含第三方许可证目录。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button("关闭", action: close)
                .keyboardShortcut(.cancelAction)
        }
        .padding(32)
        .frame(width: 420)
    }

    private func showLicenses() {
        guard let directory = Bundle.main.resourceURL?.appending(path: "Licenses", directoryHint: .isDirectory),
              FileManager.default.fileExists(atPath: directory.path) else {
            licensesUnavailable = true
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    private func close() {
        dismiss()
    }
}
