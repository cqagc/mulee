import SwiftUI

/// 密码只在编辑期间留在内存，保存后写回本机钥匙串。
struct ExtractionPasswordBookSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var passwords: [String] = []
    @State private var newPassword = ""
    @State private var selection: Int?
    @State private var issue: String?
    @State private var isLoading = true
    @State private var isSaving = false

    var body: some View {
        VStack(spacing: 16) {
            Text("密码本")
                .font(.headline)
            List(passwords.indices, id: \.self, selection: $selection) { index in
                Text("密码 \((index + 1).formatted()) · " + String(repeating: "•", count: passwords[index].count))
            }
            .frame(minHeight: 160)
            HStack {
                SecureField("新增密码", text: $newPassword)
                    .onSubmit(addPassword)
                Button("添加", action: addPassword)
                    .disabled(newPassword.isEmpty || isLoading || isSaving)
                Button("移除选中密码", action: removePassword)
                    .disabled(selection == nil || isLoading || isSaving)
            }
            if let issue {
                Text(issue)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button("保存", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isLoading || isSaving)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task(load)
    }

    private func load() async {
        do {
            passwords = try await model.extractionPasswords.passwordBook()
            isLoading = false
        } catch {
            issue = "暂时无法读取密码本，已有密码已保留"
        }
    }

    private func addPassword() {
        guard !newPassword.isEmpty, !isLoading, !isSaving else { return }
        if !passwords.contains(newPassword) { passwords.append(newPassword) }
        newPassword = ""
    }

    private func removePassword() {
        guard let selection, passwords.indices.contains(selection) else { return }
        passwords.remove(at: selection)
        self.selection = nil
    }

    private func cancel() {
        dismiss()
    }

    private func save() {
        addPassword()
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await model.saveExtractionPasswordBook(passwords)
                passwords = []
                dismiss()
            } catch {
                issue = "暂时无法保存密码本，请稍后再试"
            }
        }
    }
}
