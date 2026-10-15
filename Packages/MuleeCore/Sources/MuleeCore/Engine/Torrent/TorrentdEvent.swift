struct TorrentdEvent: Codable, Sendable, Equatable {
    let event: String
    var id: String? = nil
    var version: String? = nil
    var libtorrent: String? = nil
    var listenPort: Int? = nil
    var name: String? = nil
    var message: String? = nil
}
