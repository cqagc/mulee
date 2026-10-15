struct TorrentdRequest<Parameters: Encodable & Sendable>: Encodable, Sendable {
    let id: Int
    let method: String
    let params: Parameters
}
