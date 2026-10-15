import AppKit
import SwiftUI
import MuleeCore

/// 入站连接证据及可复制的路由器转发说明。
struct PortConnectivitySection: View {
    @Environment(AppModel.self) private var appModel
    @Environment(SettingsModel.self) private var model
    @State private var diagnostics = NetworkDiagnosticsService.shared
    @State private var copied = false

    var body: some View {
        @Bindable var model = model
        let status = appModel.networkStatus
        let mapping = NetworkPresentation.portMapping(succeeded: status.portMappingSucceeded)
        Section(NetworkPresentation.portCardTitle) {
            NetworkPortStatusRow(title: NetworkPresentation.btPortTitle,
                                 port: model.btPort, transport: "TCP / UDP",
                                 line: NetworkPresentation.bittorrentPort(reachable: status.bittorrentPortReachable))
            NetworkPortStatusRow(title: NetworkPresentation.ed2kTCPTitle,
                                 port: model.ed2kTCPPort, transport: "TCP",
                                 line: NetworkPresentation.ed2kID(status.ed2kID))
            NetworkPortStatusRow(title: NetworkPresentation.ed2kUDPTitle,
                                 port: model.ed2kUDPPort, transport: "UDP",
                                 line: NetworkPresentation.kadBadge(status.kad))
            Text(NetworkPresentation.portSummary(status))
                .font(.callout)
                .foregroundStyle(.secondary)
            if status.bittorrentPortReachable != true || status.ed2kID != .high || status.kad != .open {
                Text(instructions)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button(copied ? NetworkPresentation.instructionsCopied : NetworkPresentation.copyInstructions,
                       systemImage: MuleeSymbol.copy.name, action: copyInstructions)
            }
            LabeledContent {
                VStack(alignment: .trailing, spacing: 4) {
                    Toggle(NetworkPresentation.mappingTitle, isOn: $model.portMapping)
                        .toggleStyle(.switch)
                        .labelsHidden()
                    if let mapping {
                        Text(mapping.text)
                            .font(.caption)
                            .foregroundStyle(mapping.isAbnormal ? Theme.wait : Theme.success)
                    }
                }
            } label: {
                Text(NetworkPresentation.mappingTitle)
                Text(NetworkPresentation.mappingAdvice)
            }
        }
    }

    private var instructions: String {
        NetworkPresentation.forwardingInstructions(btPort: model.btPort, tcpPort: model.ed2kTCPPort,
                                                   udpPort: model.ed2kUDPPort, network: diagnostics.snapshot)
    }

    private func copyInstructions() {
        NSPasteboard.general.clearContents()
        copied = NSPasteboard.general.setString(instructions, forType: .string)
    }
}

#Preview {
    Form { PortConnectivitySection() }
        .formStyle(.grouped)
        .environment(AppModel(networkStatus: MockData.proxiedNetwork))
        .environment(SettingsModel())
}
