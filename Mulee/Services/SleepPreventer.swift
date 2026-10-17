import Foundation

/// 有下载在进行时阻止系统空闲睡眠，全部完成后释放。
final class SleepPreventer {
    private let provider: any PowerAssertionProviding
    private var assertionID: UInt32?
    private let lowPowerMode: () -> Bool
    private var requested = false
    private var observer: NSObjectProtocol?

    var isPreventingSleep: Bool {
        assertionID != nil
    }

    init(
        provider: any PowerAssertionProviding = IOKitPowerAssertionProvider(),
        lowPowerMode: @escaping () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled }
    ) {
        self.provider = provider
        self.lowPowerMode = lowPowerMode
        observer = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.update(isActive: self.requested)
            }
        }
    }

    isolated deinit {
        release()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// 幂等：状态没变时什么都不做。
    func update(isActive: Bool) {
        requested = isActive
        if isActive && !lowPowerMode() {
            guard assertionID == nil else { return }
            assertionID = provider.createAssertion(reason: String(localized: "Mulee 正在下载"))
        } else {
            release()
        }
    }

    private func release() {
        guard let assertionID else { return }
        provider.releaseAssertion(assertionID)
        self.assertionID = nil
    }
}
