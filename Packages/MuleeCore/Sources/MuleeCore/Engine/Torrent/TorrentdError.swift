struct TorrentdError: Codable, Sendable {
    let code: String
    let message: String
}
