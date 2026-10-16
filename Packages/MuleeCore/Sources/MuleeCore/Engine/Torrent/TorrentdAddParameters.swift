struct TorrentdAddParameters: Codable, Sendable {
    var magnet: String? = nil
    var torrentFile: String? = nil
    var savePath: String? = nil
    var paused: Bool = false
    var markIncomplete: Bool = true
    var source: String? = nil
    var filePriorities: [Int]? = nil
}
