import Foundation

/// EC 只用于本机控制；错误不包含密码或认证报文。
enum ECError: Error, Sendable, Equatable, LocalizedError {
    case malformed(String)
    case timeout
    case disconnected
    case authentication
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .malformed(let reason): "电驴引擎响应异常：\(reason)"
        case .timeout: "电驴引擎请求超时"
        case .disconnected: "电驴引擎连接已断开"
        case .authentication: "电驴引擎认证失败，请检查本机配置"
        case .rejected(let reason): "电驴引擎无法执行操作：\(reason)"
        }
    }
}
