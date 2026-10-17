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
    public let isFinished: Bool
    public let sequentialDownload: Bool
    public let firstLastPriority: Bool
    public let diagnostics: TorrentDiagnostics?
    public let seedTimeSeconds: Int64
    public let seedInactiveSeconds: Int64
    public var userDownloadLimit: Int64 = 0
    public var userUploadLimit: Int64 = 0
}

/// 以一秒为最短间隔采样的 BT 连接诊断；磁盘指标属于整个会话。
public struct TorrentDiagnostics: Codable, Sendable, Equatable {
    public let connectedPeers: Int
    public let peerSources: TorrentPeerSources
    public let ipv4: Int
    public let ipv6: Int
    public let tcp: Int
    public let utp: Int
    public let trackersAvailable: Int
    public let trackersFailed: Int
    public let trackersPending: Int
    public let lastTrackerError: String?
    /// 尚未取得 session stats 时为 nil。
    public let diskBacklogged: Bool?
    public let queuedDiskBytes: Int64
    public let diskBlockedPeers: Int
    public let diskQueueLimit: Int64
    /// 当前辅助进程会话内，该任务被规则断开的连接次数。
    public let blockedClientsCount: Int64
}

/// 来源位可以重叠，合计不一定等于连接总数；恢复或显式 peer 可能没有这些来源位。
public struct TorrentPeerSources: Codable, Sendable, Equatable {
    public let tracker: Int
    public let dht: Int
    public let pex: Int
    public let lsd: Int
    public let incoming: Int
}
