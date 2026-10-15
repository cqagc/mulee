import MuleeCore
import SwiftUI

/// 新增解压密码规则。
struct AddUnzipRuleSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var kind = UnzipRule.MatchKind.sourceSite
    @State private var pattern = ""
    @State private var password = ""
    @State private var isSaving = false
    @State private var storageIssue: String?

    private var canSave: Bool {
        !pattern.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker("匹配方式", selection: $kind) {
                    ForEach(UnzipRule.MatchKind.allCases.filter { $0 != .passwordBook }, id: \.self) { kind in
                        Label(UnzipRulesTable.title(for: kind), systemImage: UnzipRulesTable.symbol(for: kind).name)
                            .tag(kind)
                    }
                }
                TextField("条件", text: $pattern, prompt: Text("域名、前缀或正则"))
                    .font(.body.monospaced())
                SecureField("密码", text: $password)
                if let storageIssue {
                    Text(storageIssue)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("取消", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("保存", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave || isSaving)
            }
            .padding([.horizontal, .bottom])
        }
        .frame(width: 420)
    }

    private func cancel() {
        dismiss()
    }

    private func save() {
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await appModel.addUnzipRule(
                    kind: kind, pattern: pattern.trimmingCharacters(in: .whitespacesAndNewlines), password: password
                )
                password = ""
                dismiss()
            } catch {
                storageIssue = "暂时无法保存密码，规则尚未添加"
            }
        }
    }
}

#Preview {
    AddUnzipRuleSheet()
        .environment(AppModel())
}
