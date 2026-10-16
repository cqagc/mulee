import MuleeCore
import SwiftUI

/// 设置·BT。
struct BitTorrentSettingsTab: View {
    @Environment(SettingsModel.self) private var model
    @State private var newPatterns = ""

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("达到做种限制后", selection: $model.seedingAction) {
                    Text("停止").tag(SettingsModel.SeedingAction.stop)
                    Text("降速到 50 KB/s 继续做种").tag(SettingsModel.SeedingAction.throttle)
                    Text("删除任务（保留文件）").tag(SettingsModel.SeedingAction.remove)
                }
                Text("分享率达到 1:1，或达到以下任一时长后执行。")
                    .foregroundStyle(.secondary)
                BitTorrentLimitField(title: "做种时长", minutes: $model.seedTimeLimitMinutes)
                BitTorrentLimitField(title: "不活跃时长", minutes: $model.seedInactiveLimitMinutes)
                BitTorrentLimitField(title: "私有种子最低做种时长", minutes: $model.privateMinSeedMinutes)
                Toggle(isOn: $model.privateIgnoresRatio) {
                    Text("私有种子不按分享率自动停止")
                    Text("私有站点可能要求持续做种；最低做种时长内不会执行限制动作。")
                }
            }
            Section("无用文件过滤") {
                Toggle("自动跳过无用文件", isOn: $model.skipJunkFiles)
                Text("添加 BT 任务时跳过匹配的文件，可在新建下载面板里重新勾选。每行一个通配规则，空行忽略，重复规则只保留一份。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(model.junkFilePatterns, id: \.self) { pattern in
                    LabeledContent {
                        Button("移除", role: .destructive) {
                            model.junkFilePatterns.removeAll { $0 == pattern }
                        }
                    } label: {
                        Text(pattern).textSelection(.enabled)
                    }
                }
                TextField("新增通配规则", text: $newPatterns, axis: .vertical)
                    .lineLimit(2...4)
                HStack {
                    Button("添加规则") {
                        model.junkFilePatterns = Self.normalizedPatterns(
                            (model.junkFilePatterns + [newPatterns]).joined(separator: "\n")
                        )
                        newPatterns = ""
                    }
                    .disabled(Self.normalizedPatterns(newPatterns).isEmpty)
                    Button("恢复默认") {
                        model.junkFilePatterns = TorrentEngineSettings.defaultJunkFilePatterns
                        newPatterns = ""
                    }
                }
            }
            Section {
                Toggle(isOn: $model.blockLeechingClients) {
                    Text("屏蔽只下载不上传的客户端")
                    Text("按客户端标识识别（目前为迅雷 -XL），可能误判。")
                }
            }
            PublicTrackerSettingsSection()
            BitTorrentBlocklistSettingsSection()
            BitTorrentWatchSettingsSection()
            Section {
                Toggle("自动端口映射", isOn: $model.portMapping)
                LabeledContent("BT 端口") {
                    TextField("BT 端口", value: $model.btPort, format: .number.grouping(.never))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                }
            }
        }
        .formStyle(.grouped)
    }
    static func normalizedPatterns(_ text: String) -> [String] {
        var seen: Set<String> = []
        return text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

#if DEBUG
#Preview {
    BitTorrentSettingsTab()
        .environment(SettingsModel())
        .environment(AppModel())
}
#endif
