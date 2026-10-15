import SwiftUI
import MuleeCore

/// 设置·网络：端口与连通性。
struct PortConnectivitySection: View {
    @Environment(AppModel.self) private var appModel
    @Environment(SettingsModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let status = appModel.networkStatus
        let ed2k = NetworkPresentation.ed2kID(status.ed2kID)
        let kad = NetworkPresentation.kadBadge(status.kad)
        let bt = NetworkPresentation.bittorrentPort(reachable: status.bittorrentPortReachable)
        let mapping = NetworkPresentation.portMapping(succeeded: status.portMappingSucceeded)
        Section("端口与连通性") {
            LabeledContent {
                HStack(spacing: 4) {
                    Image(systemName: MuleeSymbol.statusDot.name)
                        .imageScale(.small)
                    Text(ed2k.text)
                }
                .fontWeight(.semibold)
                .foregroundStyle(ed2k.isAbnormal ? Theme.wait : Theme.success)
            } label: {
                Text("电驴端口")
                Text("TCP \(model.ed2kTCPPort.formatted(.number.grouping(.never))) · UDP \(model.ed2kUDPPort.formatted(.number.grouping(.never)))")
            }
            LabeledContent {
                Text(kad.text)
                    .fontWeight(.semibold)
                    .foregroundStyle(kad.isAbnormal ? Theme.wait : Theme.success)
            } label: {
                Text("Kad 网络")
                Text(NetworkPresentation.kadDescription(status.kad))
            }
            LabeledContent {
                HStack {
                    Text(bt.text)
                        .foregroundStyle(bt.isAbnormal ? Theme.wait : .secondary)
                    if status.bittorrentPortReachable == nil {
                        Button("测试", action: testBitTorrentPort)
                    }
                }
            } label: {
                Text("BT 端口")
                Text("TCP / UDP \(model.btPort.formatted(.number.grouping(.never)))")
            }
            LabeledContent {
                HStack {
                    if let mapping {
                        Text(mapping.text)
                            .fontWeight(.semibold)
                            .foregroundStyle(mapping.isAbnormal ? Theme.wait : Theme.success)
                    }
                    Toggle("自动端口映射", isOn: $model.portMapping)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            } label: {
                Text("自动端口映射（UPnP / NAT-PMP）")
                Text("路由器支持时自动打开端口，是拿到 High ID 最省事的办法")
            }
        }
    }

    private func testBitTorrentPort() {
        // TODO: 引擎接入后检测 BT 端口是否可从外部连入。
    }
}

#Preview {
    Form { PortConnectivitySection() }
        .formStyle(.grouped)
        .environment(AppModel(networkStatus: MockData.proxiedNetwork))
        .environment(SettingsModel())
}
