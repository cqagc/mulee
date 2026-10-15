struct TorrentdResponse: Codable, Sendable {
    let id: Int
    let result: TorrentdValue?
    let error: TorrentdError?
}
