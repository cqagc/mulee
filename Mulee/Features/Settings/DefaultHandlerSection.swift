import SwiftUI

struct DefaultHandlerSection: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var names: [DefaultHandlerKind: String] = [:]
    @State private var isUpdating = false
    @State private var issue: String?

    var body: some View {
        Section("默认打开方式") {
            Text("打开链接或种子文件后，在「新建下载」面板确认才会开始下载。")
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach(DefaultHandlerKind.allCases) { kind in
                LabeledContent(kind.title) {
                    Text(names[kind] ?? "正在读取…")
                        .foregroundStyle(.secondary)
                    Button("设为 Mulee") { setDefaults([kind]) }
                        .accessibilityLabel("将 \(kind.title) 设为 Mulee")
                        .disabled(isUpdating)
                }
            }
            Button("全部设为 Mulee", action: setAllDefaults)
                .disabled(isUpdating)
            if let issue {
                Text(issue)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .task { refresh() }
        .onChange(of: scenePhase) {
            if scenePhase == .active { refresh() }
        }
    }

    private func refresh() {
        names = Dictionary(uniqueKeysWithValues: DefaultHandlerKind.allCases.map { ($0, $0.applicationName) })
    }

    private func setAllDefaults() {
        setDefaults(DefaultHandlerKind.allCases)
    }

    private func setDefaults(_ kinds: [DefaultHandlerKind]) {
        isUpdating = true
        issue = nil
        Task {
            var failures: [String] = []
            for kind in kinds {
                do { try await kind.setMulee() }
                catch { failures.append("\(kind.title)：\(error.localizedDescription)") }
                refresh()
            }
            issue = failures.isEmpty ? nil : failures.joined(separator: "\n")
            isUpdating = false
        }
    }
}
