import IOKit.pwr_mgt

/// 用 IOKit 电源断言实现 `PowerAssertionProviding`。
struct IOKitPowerAssertionProvider: PowerAssertionProviding {
    func createAssertion(reason: String) -> UInt32? {
        var assertionID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )
        return result == kIOReturnSuccess ? assertionID : nil
    }

    func releaseAssertion(_ id: UInt32) {
        IOPMAssertionRelease(id)
    }
}
