import Foundation

public struct UnzipRuleMatch: Sendable {
    public let sources: [UnzipPasswordSource]
    public let matchedRule: UnzipRule?
    public let errors: [String]
}
