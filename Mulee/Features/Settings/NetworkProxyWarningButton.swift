import AppKit
import SwiftUI

/// 侧边栏和菜单栏共用的入口。
struct NetworkProxyWarningButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button(NetworkPresentation.proxyWarning, systemImage: MuleeSymbol.proxyWarning.name,
               action: showNetworkSettings)
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(Theme.wait)
    }

    private func showNetworkSettings() {
        NetworkSettingsNavigation.shared.selection = .network
        openSettings()
        NSApplication.shared.activate()
    }
}
