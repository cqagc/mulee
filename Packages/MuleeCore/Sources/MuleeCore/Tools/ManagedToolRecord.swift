import Foundation

/// 已安装工具的可验证版本信息。
public struct ManagedToolRecord: Codable, Sendable, Equatable {
    public let version: String
    public let updatedAt: Date
    public let sha256: String
}
