import MuleeCore
import SwiftUI

struct NetworkStatusView: View {
    @Environment(AppModel.self) private var model
    let status: NetworkStatus

    var body: some View {
        let engineState = model.engineStates[.http] ?? .unavailable
        let btState = model.engineStates[.bittorrent] ?? .unavailable
        let videoState = model.engineStates[.video] ?? .unavailable
        VStack(spacing: 8) {
            Divider()
                .padding(.bottom, 4)
            NetworkStatusRow(title: "下载引擎", value: EngineStatusPresentation.title(for: engineState), isHealthy: engineState == .unavailable ? nil : engineState == .running)
            NetworkStatusRow(title: "视频引擎", value: EngineStatusPresentation.videoTitle(for: videoState), isHealthy: videoState == .unavailable ? nil : videoState == .running)
            NetworkStatusRow(title: "BT 引擎", value: EngineStatusPresentation.videoTitle(for: btState), isHealthy: btState == .unavailable ? nil : btState == .running)
            if let issue = model.bitTorrent?.issue {
                Text(issue)
                    .foregroundStyle(Theme.wait)
                    .lineLimit(2)
                    .help(issue)
            }
            NetworkStatusRow(title: "电驴", value: NetworkPresentation.ed2kID(status.ed2kID).text, isHealthy: status.ed2kID == .disconnected ? nil : status.ed2kID == .high)
            NetworkStatusRow(title: "电驴来源网络", value: NetworkPresentation.kadBadge(status.kad).text, isHealthy: status.kad == .disconnected ? nil : status.kad == .open)
            NetworkStatusRow(title: "BT 端口", value: NetworkPresentation.bittorrentPort(reachable: status.bittorrentPortReachable).text, isHealthy: status.bittorrentPortReachable)
            if status.p2pRoutedThroughProxy {
                NetworkProxyWarningButton()
            }
        }
        .font(.caption)
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }
}
