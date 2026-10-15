import SwiftUI

/// 各场景共享设置，同步防睡眠状态与引擎配置。
struct SettingsSyncModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(SettingsModel.self) private var settings

    func body(content: Content) -> some View {
        content
            .onChange(of: settings.preventSleep, initial: true) {
                model.preventsSleepWhileDownloading = settings.preventSleep
            }
            .onChange(of: settings.allowSleepWhenDone, initial: true) {
                model.allowsSleepWhenDone = settings.allowSleepWhenDone
            }
            .onChange(of: settings.watchClipboard) {
                model.settingsRuntime?.refresh()
            }
            .onChange(of: EngineOptionsMapper.options(from: settings)) {
                model.coordinator?.apply(options: EngineOptionsMapper.options(from: settings))
            }
            .onChange(of: BitTorrentEngineConfiguration.configuration(from: settings)) {
                model.bitTorrent?.configure(BitTorrentEngineConfiguration.configuration(from: settings))
            }
            .onChange(of: Ed2kEngineConfiguration.configuration(from: settings)) {
                model.ed2k?.configure(Ed2kEngineConfiguration.configuration(from: settings))
            }
            .onChange(of: VideoEngineConfiguration.configuration(from: settings)) {
                model.coordinator?.configureVideo(VideoEngineConfiguration.configuration(from: settings))
            }
    }
}
