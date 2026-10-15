import MuleeCore
import SwiftUI

struct NetworkStatusView: View {
    @Environment(AppModel.self) private var model
    let status: NetworkStatus

    var body: some View {
        let engineState = model.engineStates[.http] ?? .unavailable
        VStack(spacing: 8) {
            Divider()
                .padding(.bottom, 4)
            NetworkStatusRow(title: "下载引擎", value: EngineStatusPresentation.title(for: engineState), isHealthy: engineState == .unavailable ? nil : engineState == .running)
            NetworkStatusRow(title: "电驴", value: EngineStatusPresentation.ed2k(status.ed2kID), isHealthy: status.ed2kID == .disconnected ? nil : status.ed2kID == .high)
            NetworkStatusRow(title: "Kad", value: EngineStatusPresentation.kad(status.kad), isHealthy: status.kad == .disconnected ? nil : status.kad == .open)
            NetworkStatusRow(title: "BT 端口", value: EngineStatusPresentation.port(status.bittorrentPortReachable), isHealthy: status.bittorrentPortReachable)
            NetworkStatusRow(title: "P2P 出口", value: EngineStatusPresentation.exit(status), isHealthy: status.p2pExitIP == nil ? nil : !status.p2pRoutedThroughProxy)
        }
        .font(.caption)
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }
}
