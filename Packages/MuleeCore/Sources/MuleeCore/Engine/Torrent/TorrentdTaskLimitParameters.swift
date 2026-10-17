struct TorrentdTaskLimitParameters: Codable, Sendable {
    let id: String
    let downloadLimit: Int64
    let uploadLimit: Int64
}
