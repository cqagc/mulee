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
        case .malformed(let reason): String(localized: "电驴引擎响应异常：\(reason)", bundle: .module)
        case .timeout: String(localized: "电驴引擎请求超时", bundle: .module)
        case .disconnected: String(localized: "电驴引擎连接已断开", bundle: .module)
        case .authentication: String(localized: "电驴引擎认证失败，请检查本机配置", bundle: .module)
        case .rejected(let reason): String(localized: "电驴引擎无法执行操作：\(reason)", bundle: .module)
        }
    }
}
