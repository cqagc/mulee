struct TorrentdIDParameters: Codable, Sendable {
    let id: String
}

/// 按任务完整替换两个下载模式开关。
struct TorrentdDownloadModeParameters: Encodable, Sendable {
    let id: String
    let sequentialDownload: Bool
    let firstLastPriority: Bool
}

/// 给任务追加 tracker 的请求。
struct TorrentdTrackersParameters: Encodable, Sendable {
    let id: String
    let urls: [String]
    var subscription: Bool = false
}

/// tracker 追加结果，重复 URL 不计入 added。
public struct TorrentTrackerAdditionResult: Decodable, Sendable, Equatable {
    public let added: Int
    public let total: Int
}

/// 移动时对目标同名文件的处理方式。
public enum TorrentStorageConflict: String, Codable, Sendable {
    case fail
    case keep
    case overwrite
}

struct TorrentdMoveParameters: Encodable, Sendable {
    let id: String
    let path: String
    let conflict: TorrentStorageConflict
}

struct TorrentdRenameParameters: Encodable, Sendable {
    let id: String
    let path: String
    let newPath: String
}

/// Tracker 的可编辑配置；subscription 标记来自公共订阅的条目。
public struct TorrentTracker: Codable, Sendable, Equatable {
    public let url: String
    public let tier: Int
    public let subscription: Bool

    public init(url: String, tier: Int = 0, subscription: Bool = false) {
        self.url = url
        self.tier = tier
        self.subscription = subscription
    }
}

/// Tracker 的当前状态和最后一次宣告结果；disabledUntil 为 Unix 秒，0 表示启用。
public struct TorrentTrackerStatus: Decodable, Sendable, Equatable {
    public let url: String
    public let tier: Int
    public let status: String
    public let lastResult: String
    public let peers: Int
    public let disabledUntil: Int64
    public let subscription: Bool
}

struct TorrentdTrackerList: Decodable, Sendable {
    let trackers: [TorrentTrackerStatus]
}

struct TorrentdSetTrackersParameters: Encodable, Sendable {
    let id: String
    let trackers: [TorrentTracker]
}

/// 当前连接节点的地址、传输协议、来源和传输状态。
public struct TorrentPeer: Decodable, Sendable, Equatable {
    public let address: String
    public let port: Int
    public let client: String
    public let progress: Double
    public let downloadRate: Int64
    public let uploadRate: Int64
    public let sources: [String]
    public let connection: String
}

struct TorrentdPeerList: Decodable, Sendable {
    let peers: [TorrentPeer]
}

struct TorrentdBanParameters: Encodable, Sendable {
    let ip: String
}

struct TorrentdPathParameters: Encodable, Sendable {
    let path: String
}

/// 导入 IP 黑名单的有效屏蔽范围数。
public struct TorrentBlocklistResult: Decodable, Sendable, Equatable {
    public let blockedRanges: Int
}

struct TorrentdCreateParameters: Encodable, Sendable {
    let path: String
    let output: String
    let `private`: Bool
    let trackers: [String]
    let comment: String?
}

struct TorrentdExportParameters: Encodable, Sendable {
    let id: String
    let output: String
}

/// 制作或导出的种子位置及 info hash。
public struct TorrentFileResult: Decodable, Sendable, Equatable {
    public let path: String
    public let id: String
}
