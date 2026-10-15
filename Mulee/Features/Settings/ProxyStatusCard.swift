import AppKit
import MuleeCore
import SwiftUI

/// 代理证据与端口可达性分开解释，不把代理检测当作端口检测。
struct ProxyStatusCard: View {
    @Environment(AppModel.self) private var appModel
    @State private var diagnostics = NetworkDiagnosticsService.shared
    @State private var copied = false

    static let rules = NetworkPresentation.rules

    var body: some View {
        let kind = appModel.networkStatus.p2pRoutedThroughProxy ? .tunnel : diagnostics.snapshot.proxyKind
        Section(NetworkPresentation.proxyCardTitle) {
            VStack(alignment: .leading, spacing: 8) {
                Label(NetworkPresentation.proxyTitle(kind), systemImage: kind == .tunnel
                      ? MuleeSymbol.proxyWarning.name : MuleeSymbol.network.name)
                    .font(.headline)
                    .foregroundStyle(kind == .tunnel ? Theme.wait : .primary)
                Text(NetworkPresentation.proxyDescription(kind))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let ip = appModel.networkStatus.p2pExitIP {
                    Text(NetworkPresentation.exitDescription(ip))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if kind == .tunnel {
                    Text(Self.rules)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(.background, in: .rect(cornerRadius: Theme.rowCornerRadius))
                    if diagnostics.snapshot.usesFakeIP {
                        Text(NetworkPresentation.fakeIPAdvice)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button(copied ? NetworkPresentation.rulesCopied : NetworkPresentation.copyRules,
                           systemImage: MuleeSymbol.copy.name, action: copyRules)
                    Button(diagnostics.isRefreshing ? NetworkPresentation.checking : NetworkPresentation.recheck,
                           systemImage: MuleeSymbol.retry.name, action: recheck)
                        .disabled(diagnostics.isRefreshing)
                }
                Text(NetworkPresentation.processRecognition)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 4)
        }
    }

    private func copyRules() {
        NSPasteboard.general.clearContents()
        copied = NSPasteboard.general.setString(Self.rules, forType: .string)
    }

    private func recheck() {
        diagnostics.refresh()
    }
}

#Preview {
    Form { ProxyStatusCard() }
        .formStyle(.grouped)
        .environment(AppModel(networkStatus: MockData.proxiedNetwork))
}
