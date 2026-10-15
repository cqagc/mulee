import MuleeCore
import SwiftUI

struct NetworkStatusView: View {
    @Environment(AppModel.self) private var model
    let status: NetworkStatus

    var body: some View {
        let engineState = model.engineStates[.http] ?? .unavailable
        let btState = model.engineStates[.bittorrent] ?? .unavailable
        let ed2kState = model.engineStates[.ed2k] ?? .unavailable
        let videoState = model.engineStates[.video] ?? .unavailable
        VStack(spacing: 8) {
            Divider()
                .padding(.bottom, 4)
            NetworkStatusRow(title: String(localized: "下载引擎"), value: EngineStatusPresentation.title(for: engineState), isHealthy: engineState == .unavailable ? nil : engineState == .running)
            NetworkStatusRow(title: String(localized: "视频引擎"), value: EngineStatusPresentation.videoTitle(for: videoState), isHealthy: videoState == .unavailable ? nil : videoState == .running)
            NetworkStatusRow(title: String(localized: "BT 引擎"), value: EngineStatusPresentation.videoTitle(for: btState), isHealthy: btState == .unavailable ? nil : btState == .running)
            NetworkStatusRow(title: String(localized: "电驴引擎"), value: EngineStatusPresentation.videoTitle(for: ed2kState), isHealthy: ed2kState == .unavailable ? nil : ed2kState == .running)
            if let issue = model.ed2k?.issue {
                Text(issue)
                    .foregroundStyle(Theme.wait)
                    .lineLimit(2)
                    .help(issue)
            }
            if let issue = model.bitTorrent?.issue {
                Text(issue)
                    .foregroundStyle(Theme.wait)
                    .lineLimit(2)
                    .help(issue)
            }
            NetworkStatusRow(title: String(localized: "电驴"), value: NetworkPresentation.sidebarReachability(ed2k: status.ed2kID), isHealthy: status.ed2kID == .disconnected ? nil : status.ed2kID == .high)
            NetworkStatusRow(title: "Kad", value: NetworkPresentation.sidebarReachability(kad: status.kad), isHealthy: status.kad == .disconnected ? nil : status.kad == .open)
            NetworkStatusRow(title: String(localized: "BT 端口"), value: NetworkPresentation.bittorrentPort(reachable: status.bittorrentPortReachable).text, isHealthy: status.bittorrentPortReachable)
            if status.p2pRoutedThroughProxy {
                NetworkProxyWarningButton()
            }
        }
        .font(.caption)
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }
}
