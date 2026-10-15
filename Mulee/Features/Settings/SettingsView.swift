import SwiftUI

/// 设置窗口：七个标签页。
struct SettingsView: View {
    @Environment(SettingsModel.self) private var model
    @State private var navigation = NetworkSettingsNavigation.shared

    var body: some View {
        @Bindable var navigation = navigation
        TabView(selection: $navigation.selection) {
            Tab(SettingsTab.general.title, systemImage: SettingsTab.general.symbol.name, value: .general) {
                GeneralSettingsTab()
            }
            Tab(SettingsTab.download.title, systemImage: SettingsTab.download.symbol.name, value: .download) {
                DownloadSettingsTab()
            }
            Tab(SettingsTab.network.title, systemImage: SettingsTab.network.symbol.name, value: .network) {
                NetworkSettingsTab()
            }
            Tab(SettingsTab.bittorrent.title, systemImage: SettingsTab.bittorrent.symbol.name, value: .bittorrent) {
                BitTorrentSettingsTab()
            }
            Tab(SettingsTab.ed2k.title, systemImage: SettingsTab.ed2k.symbol.name, value: .ed2k) {
                Ed2kSettingsTab()
            }
            Tab(SettingsTab.video.title, systemImage: SettingsTab.video.symbol.name, value: .video) {
                VideoSettingsTab()
            }
            Tab(SettingsTab.unzip.title, systemImage: SettingsTab.unzip.symbol.name, value: .unzip) {
                UnzipSettingsTab()
            }
        }
        .environment(model)
        .frame(width: 720)
        .frame(minHeight: 480)
        #if DEBUG
        .task(selectDebugLaunchTab)
        #endif
    }

    #if DEBUG
    /// Debug 启动参数 -MuleeSettingsTab 指定的标签页（用于截图核对）。
    private func selectDebugLaunchTab() async {
        if let raw = DebugLaunchOptions.settingsTab, let tab = SettingsTab(rawValue: raw) {
            navigation.selection = tab
        }
    }
    #endif
}

#Preview {
    SettingsView()
        .environment(AppModel())
        .environment(SettingsModel())
}
