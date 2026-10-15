import SwiftUI

/// 各场景共享设置，并在设置变化时同步防睡眠状态。
struct SettingsSyncModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(SettingsModel.self) private var settings

    func body(content: Content) -> some View {
        content
            .onChange(of: settings.preventSleep, initial: true) {
                model.preventsSleepWhileDownloading = settings.preventSleep
            }
    }
}
