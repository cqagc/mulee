/// 选中任务时按需读取的 BT 连接与做种信息。
public struct TorrentTaskInfo: Sendable, Equatable {
    public let numPeers: Int
    public let numSeeds: Int
    public let listPeers: Int
    public let listSeeds: Int
    public let ratio: Double
    public let isPrivate: Bool
    public let uploadLimit: Int64
    public let hasMetadata: Bool
}
