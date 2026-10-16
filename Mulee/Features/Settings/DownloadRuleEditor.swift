import MuleeCore
import SwiftUI

struct DownloadRuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var rule: DownloadRule
    @State private var extensionsText = ""
    let save: (DownloadRule) -> Void

    private var valid: Bool {
        !rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (rule.subdirectory.isEmpty || rule.saveDirectory(under: URL(filePath: "/")) != nil)
            && !(rule.userAgent ?? "").contains(where: { $0.isNewline || $0 == "\0" })
    }

    var body: some View {
        Form {
            TextField("规则名称", text: $rule.name)
            TextField("来源网站（支持 *，留空不限）", text: $rule.sourceSite)
            TextField("扩展名（逗号分隔，留空不限）", text: $extensionsText)
            Picker("任务类型", selection: $rule.taskKind) {
                Text("不限").tag(TaskKind?.none)
                Text("网页 HTTP").tag(TaskKind?.some(.http))
                Text("BT / 磁力").tag(TaskKind?.some(.bittorrent))
                Text("电驴 ed2k").tag(TaskKind?.some(.ed2k))
                Text("视频").tag(TaskKind?.some(.video))
            }
            TextField("保存子目录（留空使用默认目录）", text: $rule.subdirectory)
            Section("HTTP 下载") {
                TextField("User-Agent（留空跟随请求）", text: Binding(
                    get: { rule.userAgent ?? "" }, set: { rule.userAgent = $0.isEmpty ? nil : $0 }
                ))
                Picker("线程数", selection: $rule.httpThreads) {
                    Text("跟随全局设置").tag(Int?.none)
                    ForEach(SettingsModel.httpThreadOptions, id: \.self) { count in
                        Text(count, format: .number).tag(Int?.some(count))
                    }
                }
                TextField("单任务限速（字节/秒，0 不限速）", value: Binding(
                    get: { rule.speedLimitBytes ?? 0 }, set: { rule.speedLimitBytes = max(0, $0) }
                ), format: .number)
            }
            Text("来源优先使用浏览器提供的页面网站；没有来源页面时使用下载链接。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    rule.extensions = extensionsText.components(separatedBy: CharacterSet(charactersIn: ",，"))
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                    save(rule)
                    dismiss()
                }
                .disabled(!valid)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 560)
        .onAppear { extensionsText = rule.extensions.joined(separator: ", ") }
    }
}
