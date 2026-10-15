import MuleeCore
import SwiftUI

/// 新增解压密码规则。
struct AddUnzipRuleSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var kind = UnzipRule.MatchKind.sourceSite
    @State private var pattern = ""
    @State private var password = ""

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
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("取消", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("保存", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding([.horizontal, .bottom])
        }
        .frame(width: 420)
    }

    private func cancel() {
        dismiss()
    }

    private func save() {
        // TODO: 密码写入钥匙串，keychainItemID 指向该条目；现在只保存规则并记录密码长度。
        let rule = UnzipRule(
            matchKind: kind,
            pattern: pattern.trimmingCharacters(in: .whitespaces),
            keychainItemID: nil,
            maskedLength: password.count,
            hitCount: 0
        )
        appModel.unzipRules.append(rule)
        dismiss()
    }
}

#Preview {
    AddUnzipRuleSheet()
        .environment(AppModel())
}
