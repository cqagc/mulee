import AppKit
import MuleeCore
import SwiftUI

/// 设置·网络顶部：P2P 是否经过代理。
struct ProxyStatusCard: View {
    @Environment(AppModel.self) private var appModel

    static let rules = "PROCESS-NAME,amuled,DIRECT\nPROCESS-NAME,mulee-torrentd,DIRECT"

    var body: some View {
        if appModel.networkStatus.p2pRoutedThroughProxy {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text("BT 和电驴的流量正在走代理")
                        .font(.headline)
                } icon: {
                    Image(systemName: MuleeSymbol.proxyWarning.name)
                        .foregroundStyle(Theme.wait)
                }
                Text("检测到 P2P 出口 IP 为 \(NetworkPresentation.maskedIP(appModel.networkStatus.p2pExitIP))，和你的宽带不一致。这会导致电驴 Low ID、BT 连不进来，还会消耗代理流量；部分代理服务禁止 P2P。把下面的规则加到 Stash / Clash 配置里，就能让 Mulee 的下载引擎直连。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(Self.rules)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.background, in: .rect(cornerRadius: Theme.rowCornerRadius))
                HStack {
                    Button("复制规则", systemImage: MuleeSymbol.copy.name, action: copyRules)
                    Button("重新检测", systemImage: MuleeSymbol.retry.name, action: recheck)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.wait.opacity(0.15), in: .rect(cornerRadius: Theme.cardCornerRadius))
        } else {
            Label("P2P 流量直连", systemImage: MuleeSymbol.statusCompleted.name)
                .foregroundStyle(Theme.success)
        }
    }

    private func copyRules() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.rules, forType: .string)
    }

    private func recheck() {
        // TODO: 引擎接入后重新检测 P2P 出口 IP。
    }
}

#Preview {
    ProxyStatusCard()
        .environment(AppModel(networkStatus: MockData.proxiedNetwork))
        .padding()
}
