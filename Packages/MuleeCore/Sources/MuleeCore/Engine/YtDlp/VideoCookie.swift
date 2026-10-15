import Foundation

/// 浏览器导出的最小 Cookie 字段；不提供 description，避免凭据进入诊断输出。
public struct VideoCookie: Codable, Sendable, Equatable {
    public let domain: String
    public let path: String
    public let name: String
    public let value: String
    public let secure: Bool
    public let httpOnly: Bool
    public let hostOnly: Bool
    public let expirationDate: Double?

    public init(
        domain: String, path: String, name: String, value: String,
        secure: Bool, httpOnly: Bool, hostOnly: Bool, expirationDate: Double? = nil
    ) {
        self.domain = domain
        self.path = path
        self.name = name
        self.value = value
        self.secure = secure
        self.httpOnly = httpOnly
        self.hostOnly = hostOnly
        self.expirationDate = expirationDate
    }

    public static func allows(domain: String, site: VideoSite) -> Bool {
        let host = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        let root: String
        switch site {
        case .bilibili: root = "bilibili.com"
        case .youtube: root = "youtube.com"
        case .other: return false
        }
        return host == host.lowercased()
            && host.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }
            && host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
                !label.isEmpty && label.utf8.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
            }
            && (host == root || host.hasSuffix("." + root))
    }

    public func isValid(for site: VideoSite) -> Bool {
        Self.allows(domain: domain, site: site) && domain.utf8.count <= 253
            && path.hasPrefix("/") && path.utf8.count <= 2_048
            && !name.isEmpty && name.utf8.count <= 256 && value.utf8.count <= 16_384
            && [path, name, value].allSatisfy { text in
                text.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
            }
            && !name.contains(where: { " ;=,".contains($0) })
            && (expirationDate.map { $0.isFinite && $0 >= 0 && $0 <= 253_402_300_799 } ?? true)
    }
}
