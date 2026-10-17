import Foundation

public enum HTTPDownloadFailure: Error, Sendable, Equatable, LocalizedError {
    case invalidCertificate
    case needsLogin
    case expiredLink
    case missingFile
    case webPage
    case resourceChanged
    case unknownIdentity
    case status(Int)

    public static func classify(statusCode: Int) -> Self? {
        switch statusCode {
        case 401: .needsLogin
        case 403, 410: .expiredLink
        case 404: .missingFile
        case 200..<300: nil
        default: .status(statusCode)
        }
    }

    public static func isCertificateError(_ error: URLError) -> Bool {
        [.serverCertificateHasBadDate, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
         .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired].contains(error.code)
    }

    public static func requiresCredentials(status: TaskStatus, message: String?) -> Bool {
        status == .failed && message == Self.needsLogin.localizedDescription
    }

    public var errorDescription: String? {
        switch self {
        case .invalidCertificate: String(localized: "服务器的安全证书无效，Mulee 不会继续连接", bundle: .module)
        case .needsLogin: String(localized: "服务器需要认证，请输入账号和密码后重试。", bundle: .module)
        case .expiredLink: "链接已过期或无权访问，请换个链接继续。"
        case .missingFile: "文件已被移走或删除，请换个链接继续。"
        case .webPage: "服务器把下载换成了网页，请获取新的下载链接。"
        case .resourceChanged: "文件在服务器上变了，需要确认后从头下载。"
        case .unknownIdentity: "无法确认是同一个文件，需要确认后从头下载。"
        case .status(let code): "服务器响应异常（HTTP \(code)）。"
        }
    }
}
