/// 有下载在进行时阻止系统空闲睡眠，全部完成后释放。
final class SleepPreventer {
    private let provider: any PowerAssertionProviding
    private var assertionID: UInt32?

    var isPreventingSleep: Bool {
        assertionID != nil
    }

    init(provider: any PowerAssertionProviding = IOKitPowerAssertionProvider()) {
        self.provider = provider
    }

    isolated deinit {
        release()
    }

    /// 幂等：状态没变时什么都不做。
    func update(isActive: Bool) {
        if isActive {
            guard assertionID == nil else { return }
            assertionID = provider.createAssertion(reason: "Mulee 正在下载")
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
