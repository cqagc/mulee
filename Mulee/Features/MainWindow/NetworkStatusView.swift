import MuleeCore
import SwiftUI

struct NetworkStatusView: View {
    let status: NetworkStatus

    private var ed2k: String {
        switch status.ed2kID {
        case .high: "High ID"
        case .low: "Low ID"
        case .disconnected: "未连接"
        }
    }

    private var kad: String {
        switch status.kad {
        case .open: "已连接"
        case .firewalled: "受限"
        case .disconnected: "未连接"
        }
    }

    private var port: String {
        switch status.bittorrentPortReachable {
        case true: "可达"
        case false: "不可达"
        case nil: "未检测"
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            Divider()
                .padding(.bottom, 4)
            NetworkStatusRow(title: "电驴", value: ed2k, isHealthy: status.ed2kID == .high)
            NetworkStatusRow(title: "Kad", value: kad, isHealthy: status.kad == .open)
            NetworkStatusRow(title: "BT 端口", value: port, isHealthy: status.bittorrentPortReachable == true)
            NetworkStatusRow(title: "P2P 出口", value: status.p2pRoutedThroughProxy ? "走代理" : "直连", isHealthy: !status.p2pRoutedThroughProxy)
        }
        .font(.caption)
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }
}
