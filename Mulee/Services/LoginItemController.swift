import Foundation
import Observation
import ServiceManagement

@Observable
final class LoginItemController {
    private let service: any LoginItemProviding
    private(set) var status: SMAppService.Status = .notRegistered
    private(set) var issue: String?

    var isEnabled: Bool { status == .enabled }
    var isRegistered: Bool { isEnabled || requiresApproval }
    var requiresApproval: Bool { status == .requiresApproval }

    init(service: any LoginItemProviding = SystemLoginItem()) {
        self.service = service
    }

    func refresh(settings: SettingsModel) {
        status = service.status
        // 持久化值只镜像系统状态，不用旧偏好在启动时重新注册。
        if settings.launchAtLogin != isEnabled { settings.launchAtLogin = isEnabled }
    }

    func setEnabled(_ enabled: Bool, settings: SettingsModel) {
        issue = nil
        do {
            if enabled { try service.register() }
            else { try service.unregister() }
        } catch {
            issue = String(localized: "无法更新开机启动：\(error.localizedDescription)")
        }
        refresh(settings: settings)
    }

    func openSettings() {
        service.openSettings()
    }
}
