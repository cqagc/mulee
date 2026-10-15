/// total 包含不支持、无效、过长及因密度丢弃的弹幕。
public struct DanmakuStatistics: Sendable, Equatable {
    public let total: Int
    public let written: Int
    public var dropped: Int { total - written }
}
