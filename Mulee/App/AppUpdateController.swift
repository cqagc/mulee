import AppKit
import Observation
import Sparkle

/// Sparkle 是更新偏好的唯一存储；Observation 只负责把 KVO 变化传给 SwiftUI。
@MainActor
@Observable
final class AppUpdateController: NSObject, SPUUpdaterDelegate {
    static let shared = AppUpdateController()
    let installation = AppUpdateInstallation()
    private(set) var issue: String?
    private(set) var isStarted = false
    private var revision = 0
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private let injectedUpdater: SPUUpdater?
    @ObservationIgnored private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil
    )

    init(updater: SPUUpdater? = nil) {
        injectedUpdater = updater
        super.init()
        let updater = self.updater
        observations = [
            updater.observe(\.automaticallyChecksForUpdates) { [weak self] _, _ in
                Task { @MainActor in self?.revision += 1 }
            },
            updater.observe(\.automaticallyDownloadsUpdates) { [weak self] _, _ in
                Task { @MainActor in self?.revision += 1 }
            },
            updater.observe(\.canCheckForUpdates) { [weak self] _, _ in
                Task { @MainActor in self?.revision += 1 }
            }
        ]
    }

    var updater: SPUUpdater { injectedUpdater ?? controller.updater }

    var automaticallyChecksForUpdates: Bool {
        get {
            _ = revision
            return updater.automaticallyChecksForUpdates
        }
        set { updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get {
            _ = revision
            return updater.automaticallyDownloadsUpdates
        }
        set { updater.automaticallyDownloadsUpdates = newValue }
    }

    var canCheckForUpdates: Bool {
        _ = revision
        return !AppEnvironment.isRunningUnitTests && (!isStarted || updater.canCheckForUpdates)
    }

    static func permitsAutomaticChecks(isDebug: Bool, isRunningUnitTests: Bool) -> Bool {
        !isDebug && !isRunningUnitTests
    }

    private var permitsAutomaticChecks: Bool {
        #if DEBUG
        Self.permitsAutomaticChecks(isDebug: true, isRunningUnitTests: AppEnvironment.isRunningUnitTests)
        #else
        Self.permitsAutomaticChecks(isDebug: false, isRunningUnitTests: AppEnvironment.isRunningUnitTests)
        #endif
    }

    func startAutomaticChecks() {
        guard permitsAutomaticChecks else { return }
        _ = start()
    }

    func checkForUpdates() {
        guard !AppEnvironment.isRunningUnitTests, start() else { return }
        controller.checkForUpdates(nil)
    }

    private func start() -> Bool {
        if isStarted { return true }
        do {
            try updater.start()
            isStarted = true
            issue = nil
            return true
        } catch {
            issue = String(localized: "更新暂不可用：\(error.localizedDescription)")
            return false
        }
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard !AppEnvironment.isRunningUnitTests,
              updateCheck == .updates || permitsAutomaticChecks else {
            throw NSError(domain: "com.cqagc.mulee.updates", code: 1)
        }
    }

    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }

    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        let allowed = installation.mayInstall()
        if allowed { installationPending = true }
        return allowed
    }

    func updater(
        _ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        Task { @MainActor in
            if await installation.prepareForInstallation() {
                installHandler()
            } else {
                issue = String(localized: "无法保存下载进度，暂不安装更新。")
            }
        }
        return true
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        installationPending = true
        return false
    }

    private(set) var installationPending = false

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        installation.reset()
        installationPending = false
    }
}
