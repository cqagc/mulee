import SwiftUI

/// 设置·BT。
struct BitTorrentSettingsTab: View {
    @Environment(SettingsModel.self) private var model

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
}

#if DEBUG
#Preview {
    BitTorrentSettingsTab()
        .environment(SettingsModel())
        .environment(AppModel())
}
#endif
