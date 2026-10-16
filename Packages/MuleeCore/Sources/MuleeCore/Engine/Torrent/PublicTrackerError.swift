import Foundation

public enum PublicTrackerError: Error, LocalizedError, Sendable {
    case invalidSubscriptions
    case responseTooLarge
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidSubscriptions: "订阅地址无效，请填写 HTTP 或 HTTPS 地址"
        case .responseTooLarge: "tracker 列表超过大小上限（512 KB）"
        case .invalidResponse: "订阅未返回有效的 tracker 列表"
        }
    }
}
