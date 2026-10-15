import Foundation

/// Native messaging 的独立消息类型；凭据永不进入 OpenURL 参数。
public struct VideoCookieRequest: Codable, Sendable {
    public static let maximumBytes = 524_288
    public let type: String
    public let site: VideoSite
    public let cookies: [VideoCookie]

    public init(site: VideoSite, cookies: [VideoCookie]) {
        type = "videoCookies"
        self.site = site
        self.cookies = cookies
    }

    /// 保存时要求登录凭据；读取历史空记录仍使用 parse。
    public func validateForSaving() throws {
        guard !cookies.isEmpty,
              site != .bilibili || cookies.contains(where: { $0.name == "SESSDATA" }) else {
            throw EngineError.invalidResponse(String(localized: "浏览器登录状态无效或超出限制", bundle: .module))
        }
    }

    public static func parse(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["type", "site", "cookies"],
              let records = object["cookies"] as? [[String: Any]], records.count <= 256,
              records.allSatisfy({ record in
                  let required: Set<String> = ["domain", "path", "name", "value", "secure", "httpOnly", "hostOnly"]
                  return required.isSubset(of: Set(record.keys))
                      && Set(record.keys).isSubset(of: required.union(["expirationDate"]))
              }),
              let request = try? JSONDecoder().decode(Self.self, from: data),
              request.type == "videoCookies", request.site != .other,
              request.cookies.allSatisfy({ $0.isValid(for: request.site) }) else {
            throw EngineError.invalidResponse(String(localized: "浏览器登录状态无效或超出限制", bundle: .module))
        }
        return request
    }
}
