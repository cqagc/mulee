import Foundation

/// 每个订阅单独缓存，某个来源失败时保留该来源的上次结果。
public struct PublicTrackerCache: Codable, Sendable, Equatable {
    public var entries: [String: [String]] = [:]
    public var updatedAt: Date?
    public var lastAttempt: Date?

    public init() {}

    public func trackers(for subscriptions: [[URL]]) -> [String] {
        PublicTrackerList.parse(subscriptions.compactMap(\.first).flatMap {
            entries[$0.absoluteString] ?? []
        }.joined(separator: "\n"))
    }

    public func isExpired(at now: Date) -> Bool {
        guard let lastAttempt else { return true }
        return now.timeIntervalSince(lastAttempt) >= 86_400
    }
}
