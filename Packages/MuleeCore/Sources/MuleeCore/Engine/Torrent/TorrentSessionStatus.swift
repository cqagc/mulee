/// BT 会话的端口、发现节点与连接情况。
public struct TorrentSessionStatus: Codable, Sendable, Hashable {
    public let listenPort: Int
    public let dhtNodes: Int
    public let hasIncomingConnections: Bool
    public let downloadRate: Int64
    public let uploadRate: Int64
    public let externalAddress: String?
}
