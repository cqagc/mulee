import SwiftUI

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isUpdating = false
    @State private var issue: String?

    private var isPreview: Bool {
        #if DEBUG
        DebugLaunchOptions.showsOnboarding
        #else
        false
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("将 Mulee 设为默认下载工具？")
                .font(.title2.bold())
            Text("Mulee 可以打开 magnet、ed2k、thunder 链接和 .torrent 种子文件。打开后，需在「新建下载」面板确认才会开始下载。")
                .fixedSize(horizontal: false, vertical: true)
            Text("系统会询问是否更改默认打开方式。你也可以稍后在设置中更改。")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let issue {
                Text(issue)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("以后再说", action: close)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isUpdating)
                Button("设为默认", action: setDefaults)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isUpdating || isPreview)
            }
        }
        .padding(28)
        .frame(width: 480)
        .interactiveDismissDisabled(isUpdating)
    }

    private func close() {
        dismiss()
    }

    private func setDefaults() {
        isUpdating = true
        issue = nil
        Task {
            var failures: [String] = []
            for kind in DefaultHandlerKind.allCases {
                do { try await kind.setMulee() }
                catch { failures.append("\(kind.title)：\(error.localizedDescription)") }
            }
            isUpdating = false
            if failures.isEmpty {
                dismiss()
            } else {
                issue = failures.joined(separator: "\n")
            }
        }
    }
}
