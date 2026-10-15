/// 分享率达到 1:1 后的行为。
public enum TorrentSeedingAction: String, Codable, Sendable, Hashable {
    case stop
    case slowDown
}
