struct TorrentdEvent: Codable, Sendable, Equatable {
    let event: String
    var id: String? = nil
    var version: String? = nil
    var libtorrent: String? = nil
    var listenPort: Int? = nil
    var name: String? = nil
    var message: String? = nil
    var jobId: String? = nil
    var completedPieces: Int? = nil
    var totalPieces: Int? = nil
    var processedBytes: Int64? = nil
    var totalBytes: Int64? = nil
}
