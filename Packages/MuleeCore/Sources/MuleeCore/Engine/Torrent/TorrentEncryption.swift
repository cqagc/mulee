/// BT 连接的协议加密方式。
public enum TorrentEncryption: String, Codable, Sendable, Hashable {
    case prefer
    case require
    case disable
}
