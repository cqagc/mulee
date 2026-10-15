struct TorrentdListResult: Codable, Sendable {
    let torrents: [TorrentdTask]
}
