struct TorrentdAddResult: Codable, Sendable {
    let id: String
    let name: String
    let duplicate: Bool
}
