struct TorrentdPrioritiesParameters: Codable, Sendable {
    let id: String
    let priorities: [Int]
}
