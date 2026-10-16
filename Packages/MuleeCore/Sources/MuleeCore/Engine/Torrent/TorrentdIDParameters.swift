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
}

/// tracker 追加结果，重复 URL 不计入 added。
public struct TorrentTrackerAdditionResult: Decodable, Sendable, Equatable {
    public let added: Int
    public let total: Int
}
