import Foundation
import Network

/// 网络状态通过闭包送入，测试不启动真实网络监视器。
@MainActor
final class SlowModeController {
    private let model: AppModel
    private let settings: SettingsModel
    private var monitor: NWPathMonitor?
    private var manual = false
    private var expensive = false
    private var constrained = false
    private var automaticOverride: Bool?

    init(model: AppModel, settings: SettingsModel) {
        self.model = model
        self.settings = settings
        model.slowModeController = self
    }

    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let expensive = path.isExpensive
            let constrained = path.isConstrained
            Task { @MainActor [weak self] in
                self?.networkChanged(expensive: expensive, constrained: constrained)
            }
        }
        self.monitor = monitor
        monitor.start(queue: DispatchQueue(label: "mulee.slow-mode.network"))
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
    }

    isolated deinit { monitor?.cancel() }

    func networkChanged(expensive: Bool, constrained: Bool) {
        if self.expensive != expensive || self.constrained != constrained {
            automaticOverride = nil
        }
        self.expensive = expensive
        self.constrained = constrained
        refresh()
        model.settingsRuntime?.refresh()
    }

    func toggle() {
        model.whenAllDoneController?.userDidInteract()
        let enabled = !model.isSlowModeActive
        manual = enabled
        automaticOverride = enabled
        refresh()
        model.settingsRuntime?.refresh()
    }

    func refresh() {
        let automatic = settings.slowModeOnExpensive && (expensive || constrained)
        model.isSlowModeActive = automaticOverride ?? (manual || automatic)
        model.slowModeReason = model.isSlowModeActive && automatic && automaticOverride != false
            ? (constrained ? String(localized: "低数据模式已开启，正在使用慢速模式")
                : String(localized: "当前网络按流量计费，正在使用慢速模式")) : nil
    }
}
