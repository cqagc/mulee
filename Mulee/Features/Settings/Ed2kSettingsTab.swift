import SwiftUI

/// 设置·电驴。
struct Ed2kSettingsTab: View {
    @Environment(SettingsModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("端口") {
                LabeledContent("TCP 端口") {
                    TextField("TCP 端口", value: $model.ed2kTCPPort, format: .number.grouping(.never))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                }
                LabeledContent("UDP 端口") {
                    TextField("UDP 端口", value: $model.ed2kUDPPort, format: .number.grouping(.never))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                }
            }
            Section {
                Toggle(isOn: $model.ed2kShare) {
                    Text("共享已下载文件")
                    Text("上传越多，别人给你排队越靠前")
                }
                Toggle("协议混淆", isOn: $model.ed2kObfuscation)
            }
            Section("长尾任务") {
                Text("没有来源的任务会一直挂着等待，不会自动取消")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    Ed2kSettingsTab()
        .environment(SettingsModel())
}
