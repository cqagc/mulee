import Foundation
import Sparkle

/// 只在内存中保存偏好，不写用户的 Sparkle 默认设置，也不访问网络。
@MainActor
final class AppUpdateUpdaterStub: SPUUpdater {
    private var checks = true
    private var downloads = false
    private(set) var startCount = 0

    init() {
        super.init(
            hostBundle: .main, applicationBundle: .main,
            userDriver: SPUStandardUserDriver(hostBundle: .main, delegate: nil), delegate: nil
        )
    }

    override var automaticallyChecksForUpdates: Bool {
        get { checks }
        set { checks = newValue }
    }

    override var automaticallyDownloadsUpdates: Bool {
        get { downloads }
        set { downloads = newValue }
    }

    override func start() throws { startCount += 1 }
}
