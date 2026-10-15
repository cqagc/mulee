import SwiftUI

/// 设置·BT。
struct BitTorrentSettingsTab: View {
    @Environment(SettingsModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("做种到分享率 1:1 后", selection: $model.seedingAction) {
                    Text("停止").tag(SettingsModel.SeedingAction.stop)
                    Text("降速到 50 KB/s 继续做种").tag(SettingsModel.SeedingAction.throttle)
                }
                Toggle(isOn: $model.privateIgnoresRatio) {
                    Text("私有种子不按分享率自动停止")
                    Text("PT 站有做种时长要求，按分享率自动停可能被记 H&R")
                }
            }
            Section {
                Toggle("自动端口映射（UPnP / NAT-PMP）", isOn: $model.portMapping)
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

#Preview {
    BitTorrentSettingsTab()
        .environment(SettingsModel())
}
