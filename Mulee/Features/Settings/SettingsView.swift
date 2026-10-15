import SwiftUI

/// 设置窗口：七个标签页。
struct SettingsView: View {
    @State private var model = SettingsModel()
    @State private var selection = SettingsTab.general

    var body: some View {
        TabView(selection: $selection) {
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
    }
}

#Preview {
    SettingsView()
        .environment(AppModel())
}
