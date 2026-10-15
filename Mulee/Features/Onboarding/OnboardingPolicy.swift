import Foundation

/// 在展示时记下已询问；关闭窗口也不会在下次启动重新询问。
enum OnboardingPolicy {
    static let askedKey = "MuleeDidAskDefaultHandler"

    static func claimPresentation(defaults: UserDefaults, usesSampleData: Bool, isRunningUnitTests: Bool) -> Bool {
        guard !usesSampleData, !isRunningUnitTests, !defaults.bool(forKey: askedKey) else { return false }
        defaults.set(true, forKey: askedKey)
        return true
    }
}
