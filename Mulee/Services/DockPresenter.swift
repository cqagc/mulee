import AppKit
import MuleeCore
import UserNotifications

@MainActor
final class DockPresenter {
    enum Badge: String, CaseIterable, Identifiable {
        case none
        case active
        case speed

        var id: Self { self }
        var title: String {
            switch self {
            case .none: String(localized: "不显示")
            case .active: String(localized: "正在下载的任务数")
            case .speed: String(localized: "下载速度")
            }
        }
    }

    private let model: AppModel
    private let settings: SettingsModel
    private var worker: Task<Void, Never>?

    init(model: AppModel, settings: SettingsModel) {
        self.model = model
        self.settings = settings
    }

    static func badgePermissionDenied(badge: UNNotificationSetting, authorization: UNAuthorizationStatus) -> Bool {
        badge == .disabled || authorization == .denied
    }

    static func badge(_ mode: Badge, activeCount: Int, bytesPerSecond: Int64) -> String? {
        switch mode {
        case .none: return nil
        case .active: return activeCount > 0 ? String(activeCount) : nil
        case .speed:
            guard bytesPerSecond > 0 else { return nil }
            let units: [(Int64, String)] = [(1_000_000_000, "G"), (1_000_000, "M"), (1_000, "K")]
            for (divisor, suffix) in units where bytesPerSecond >= divisor {
                let value = Double(bytesPerSecond) / Double(divisor)
                return value.formatted(.number.precision(.fractionLength(value < 10 ? 1 : 0)).locale(Locale(identifier: "en_US_POSIX"))) + suffix
            }
            return String(bytesPerSecond)
        }
    }

    func start() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
            }
        }
    }

    func refresh() {
        NSApp.dockTile.badgeLabel = NSApp.activationPolicy() == .regular
            ? Self.badge(settings.dockBadge, activeCount: model.activeTasks.filter { $0.status == .downloading }.count,
                         bytesPerSecond: model.totalDownloadRate) : nil
    }

    func stop() {
        worker?.cancel()
        worker = nil
        NSApp.dockTile.badgeLabel = nil
    }

    isolated deinit { worker?.cancel() }
}
