import Foundation

/// 浏览器或粘贴解析提供的请求信息；Cookie 只在内存与任务专属钥匙串中保留。
public struct DownloadRequestContext: Sendable, Hashable, Codable {
    public enum DuplicateAction: String, Codable, Sendable, CaseIterable {
        case rename
        case overwrite
        case ask
    }

    /// nil 保留既有引擎默认行为；ask 在新建面板确认后转换为具体策略。
    public var duplicateAction: DuplicateAction?

    public static let safariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    public var referer: URL?
    public var userAgent: String?
    public var suggestedFilename: String?
    public var headers: [String: String]
    public var cookie: String?
    public var usesStoredHTTPCredentials: Bool?

    public init(
        referer: URL? = nil, userAgent: String? = nil, suggestedFilename: String? = nil,
        headers: [String: String] = [:], cookie: String? = nil
    ) {
        self.referer = referer
        self.userAgent = userAgent
        self.suggestedFilename = suggestedFilename
        self.headers = headers
        self.cookie = cookie
    }

    public var requestCookie: String? {
        cookie ?? headers.first { $0.key.lowercased() == "cookie" }?.value
    }

    public var withoutCookie: Self {
        var value = self
        value.cookie = nil
        value.headers = headers.filter { $0.key.lowercased() != "cookie" && $0.key.lowercased() != "set-cookie" }
        return value
    }

    /// 拒绝换行和路径，避免请求头注入以及建议文件名逃逸保存目录。
    public func validate() throws {
        let values = [referer?.absoluteString, userAgent, suggestedFilename, cookie].compactMap { $0 }
            + Array(headers.keys) + Array(headers.values)
        guard values.allSatisfy({ !$0.utf8.contains(where: { [0, 10, 13].contains($0) }) }),
              headers.keys.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { byte in
                  (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                      || "!#$%&'*+-.^_`|~".utf8.contains(byte)
              } }) else {
            throw EngineError.invalidResponse(String(localized: "请求头格式无效", bundle: .module))
        }
        if let suggestedFilename {
            guard !suggestedFilename.isEmpty, ![".", ".."].contains(suggestedFilename),
                  !suggestedFilename.contains("/"), !suggestedFilename.contains("\\") else {
                throw EngineError.invalidResponse(String(localized: "建议文件名不能包含路径", bundle: .module))
            }
        }
        if let referer {
            guard ["http", "https"].contains(referer.scheme?.lowercased() ?? ""),
                  referer.host != nil, referer.user == nil, referer.password == nil else {
                throw EngineError.invalidResponse(String(localized: "来源页面链接无效", bundle: .module))
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case referer, userAgent, suggestedFilename, headers, duplicateAction, usesStoredHTTPCredentials
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        referer = try container.decodeIfPresent(URL.self, forKey: .referer)
        userAgent = try container.decodeIfPresent(String.self, forKey: .userAgent)
        suggestedFilename = try container.decodeIfPresent(String.self, forKey: .suggestedFilename)
        headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        cookie = nil
        usesStoredHTTPCredentials = try container.decodeIfPresent(Bool.self, forKey: .usesStoredHTTPCredentials)
        duplicateAction = try container.decodeIfPresent(DuplicateAction.self, forKey: .duplicateAction)
        self = withoutCookie
        headers = headers.filter { !["authorization", "proxy-authorization"].contains($0.key.lowercased()) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(usesStoredHTTPCredentials, forKey: .usesStoredHTTPCredentials)
        try container.encodeIfPresent(duplicateAction, forKey: .duplicateAction)
        try container.encodeIfPresent(referer, forKey: .referer)
        try container.encodeIfPresent(userAgent, forKey: .userAgent)
        try container.encodeIfPresent(suggestedFilename, forKey: .suggestedFilename)
        let historyHeaders = withoutCookie.headers.filter { !["authorization", "proxy-authorization"].contains($0.key.lowercased()) }
        try container.encode(historyHeaders, forKey: .headers)
    }
}
