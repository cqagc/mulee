import Observation

/// 设置窗口和网络提示共用标签选择，不依赖窗口是否已经打开。
@Observable
final class NetworkSettingsNavigation {
    static let shared = NetworkSettingsNavigation()

    var selection = SettingsTab.general
}
