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
            .onChange(of: EngineOptionsMapper.options(from: settings)) {
                model.coordinator?.apply(options: EngineOptionsMapper.options(from: settings))
            }
    }
}
