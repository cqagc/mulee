struct TorrentdBlocklistParameters: Codable, Sendable {
    let path: String
    let validateOnly: Bool
}
