import Foundation

/// 登录状态只走 Native Messaging；错误与调试描述不包含凭据。
public struct DownloadCookieRequest: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let maximumBytes = 65_536
    public let type: String
    public let token: String
    public let url: URL
    public let cookie: String

    public var description: String { "DownloadCookieRequest(redacted)" }
    public var debugDescription: String { description }

    public static func isValidToken(_ token: String) -> Bool {
        token.utf8.count == 32 && token.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    public static func parse(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["type", "token", "url", "cookie"],
              let request = try? JSONDecoder().decode(Self.self, from: data),
              request.type == "downloadCookies", isValidToken(request.token),
              ["http", "https"].contains(request.url.scheme?.lowercased() ?? ""), request.url.host != nil,
              request.url.user == nil, request.url.password == nil, !request.cookie.isEmpty,
              !request.cookie.utf8.contains(where: { $0 < 32 || $0 == 127 }) else {
            throw EngineError.invalidResponse(String(localized: "浏览器下载登录状态无效", bundle: .module))
        }
        return request
    }
}
