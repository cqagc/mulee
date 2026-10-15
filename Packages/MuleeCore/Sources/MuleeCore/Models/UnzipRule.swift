import Foundation

/// 解压密码规则。密码本身存在钥匙串里，这里只保存钥匙串条目的标识。
public struct UnzipRule: Identifiable, Sendable, Hashable, Codable {
    public enum MatchKind: String, Sendable, Hashable, Codable, CaseIterable {
        /// 按下载来源网站（浏览器扩展提供来源页面）。
        case sourceSite
        /// 按文件名前缀，支持 * 通配。
        case filenamePrefix
        /// 按文件名正则。
        case filenameRegex
        /// 兜底：依次尝试密码本里的所有密码。
        case passwordBook
    }

    public let id: UUID
    public var matchKind: MatchKind
    /// 匹配条件：网站域名、前缀或正则；密码本规则为说明文字。
    public var pattern: String
    /// 钥匙串条目标识；密码本规则为 nil（密码本单独存储）。
    public var keychainItemID: String?
    /// 用于界面显示的密码长度（不暴露密码本身）。
    public var maskedLength: Int
    /// 累计命中次数。
    public var hitCount: Int

    public init(id: UUID = UUID(), matchKind: MatchKind, pattern: String, keychainItemID: String?, maskedLength: Int, hitCount: Int) {
        self.id = id
        self.matchKind = matchKind
        self.pattern = pattern
        self.keychainItemID = keychainItemID
        self.maskedLength = maskedLength
        self.hitCount = hitCount
    }
}
