struct TorrentdFilesResult: Codable, Sendable {
    let files: [TorrentFileEntry]
}
