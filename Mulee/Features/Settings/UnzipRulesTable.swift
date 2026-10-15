import MuleeCore
import SwiftUI

/// 解压密码规则表：匹配方式、条件、密码、命中次数。
struct UnzipRulesTable: View {
    @Environment(AppModel.self) private var appModel
    @State private var selection: UnzipRule.ID?
    @State private var isAddingRule = false
    @State private var isRemovingRule = false
    @State private var storageIssue: String?

    var body: some View {
        VStack(spacing: 0) {
            Table(appModel.unzipRules, selection: $selection) {
                TableColumn("匹配方式") { rule in
                    Label(Self.title(for: rule.matchKind), systemImage: Self.symbol(for: rule.matchKind).name)
                }
                TableColumn("条件") { rule in
                    Text(rule.pattern)
                        .font(rule.matchKind == .passwordBook ? .callout : .callout.monospaced())
                        .foregroundStyle(rule.matchKind == .passwordBook ? .secondary : .primary)
                }
                TableColumn("密码") { rule in
                    Text(rule.matchKind == .passwordBook ? "—" : String(repeating: "•", count: rule.maskedLength))
                        .foregroundStyle(.secondary)
                }
                .width(100)
                TableColumn("命中") { rule in
                    Text(rule.hitCount, format: .number)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(44)
            }
            .tableStyle(.inset)
            .frame(height: 190)
            HStack {
                Button("新增规则", systemImage: MuleeSymbol.add.name, action: addRule)
                Button("删除规则", systemImage: MuleeSymbol.remove.name, action: removeSelected)
                    .disabled(selection == nil || isRemovingRule)
                Spacer()
                Text("密码保存在钥匙串里，规则只存在本机")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .padding(8)
            if let issue = storageIssue ?? appModel.unzipRuleIssue {
                Text(issue)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
        }
        .sheet(isPresented: $isAddingRule) {
            AddUnzipRuleSheet()
        }
    }

    private func addRule() {
        isAddingRule = true
    }

    private func removeSelected() {
        guard let selection else { return }
        isRemovingRule = true
        Task {
            defer { isRemovingRule = false }
            do {
                try await appModel.removeUnzipRule(selection)
                self.selection = nil
                storageIssue = nil
            } catch {
                storageIssue = "暂时无法删除钥匙串密码，规则已保留"
            }
        }
    }

    static func title(for kind: UnzipRule.MatchKind) -> LocalizedStringKey {
        switch kind {
        case .sourceSite: "来源网站"
        case .filenamePrefix: "文件名前缀"
        case .filenameRegex: "文件名规则"
        case .passwordBook: "密码本"
        }
    }

    static func symbol(for kind: UnzipRule.MatchKind) -> MuleeSymbol {
        switch kind {
        case .sourceSite: .ruleSourceSite
        case .filenamePrefix: .ruleFilenamePrefix
        case .filenameRegex: .ruleFilenameRegex
        case .passwordBook: .rulePasswordBook
        }
    }
}

#Preview {
    UnzipRulesTable()
        .environment(AppModel())
        .frame(width: 640)
}
