struct TorrentdRemoveParameters: Codable, Sendable {
    let id: String
    let deleteFiles: Bool
}
