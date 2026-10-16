import MuleeCore
import SwiftUI

struct DownloadRulesSettingsView: View {
    @Environment(SettingsModel.self) private var model
    @State private var editing: DownloadRule?

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            Toggle("按文件分类保存到子文件夹", isOn: $model.sortIntoFolders)
            Text("规则按列表顺序匹配，第一条命中生效。未指定规则目录时，可按视频、音频、压缩包、文档、程序和镜像分类保存。")
                .font(.caption)
                .foregroundStyle(.secondary)
            List {
                ForEach(model.downloadRules) { rule in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(rule.name)
                            Text(rule.subdirectory.isEmpty ? String(localized: "使用默认目录") : rule.subdirectory)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("上移") { move(rule, offset: -1) }
                            .disabled(model.downloadRules.first?.id == rule.id)
                        Button("下移") { move(rule, offset: 1) }
                            .disabled(model.downloadRules.last?.id == rule.id)
                        Button("编辑") { editing = rule }
                        Button("删除", role: .destructive) { model.downloadRules.removeAll { $0.id == rule.id } }
                    }
                }
            }
            .frame(minHeight: 160)
            Button("添加下载规则…") { editing = DownloadRule(name: "") }
        }
        .padding()
        .frame(minWidth: 640, minHeight: 320)
        .sheet(item: $editing) { rule in
            DownloadRuleEditor(rule: rule) { updated in
                if let index = model.downloadRules.firstIndex(where: { $0.id == updated.id }) {
                    model.downloadRules[index] = updated
                } else {
                    model.downloadRules.append(updated)
                }
            }
        }
    }

    private func move(_ rule: DownloadRule, offset: Int) {
        guard let index = model.downloadRules.firstIndex(where: { $0.id == rule.id }),
              model.downloadRules.indices.contains(index + offset) else { return }
        model.downloadRules.swapAt(index, index + offset)
    }
}
