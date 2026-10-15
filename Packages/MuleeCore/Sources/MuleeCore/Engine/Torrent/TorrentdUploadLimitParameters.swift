struct TorrentdUploadLimitParameters: Codable, Sendable {
    let id: String
    let limit: Int64
}
