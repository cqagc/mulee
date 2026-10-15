import Foundation

/// 从用户粘贴的文本里识别出的一个下载链接。
public enum ParsedLink: Sendable, Hashable {
    /// 磁力链接：BTIH 哈希（40 位十六进制小写，或 32 位 base32 转换后的十六进制），以及 dn 参数里的显示名。
    case magnet(infoHash: String, displayName: String?, original: String)
    /// 本地或远程 .torrent 文件；远程文件由 BT 引擎下载后交给辅助进程。
    case torrentFile(url: URL, original: String)
    /// ed2k 文件链接：文件名（已做 URL 解码）、字节数、32 位十六进制 MD4 哈希（大写）。
    case ed2k(fileName: String, size: Int64, hash: String, original: String)
    /// HTTP / HTTPS / FTP 直链。`decodedFromThunder` 为 true 表示来自迅雷链接解析。
    case http(url: URL, decodedFromThunder: Bool, original: String)
    /// 重点视频站的页面链接。
    case video(url: URL, site: VideoSite, original: String)

    /// 对应的任务类型。
    public var kind: TaskKind {
        switch self {
        case .magnet, .torrentFile: .bittorrent
        case .ed2k: .ed2k
        case .http: .http
        case .video: .video
        }
    }

    /// 用户粘贴的原始文本。
    public var original: String {
        switch self {
        case .magnet(_, _, let original), .torrentFile(_, let original), .ed2k(_, _, _, let original),
             .http(_, _, let original), .video(_, _, let original):
            original
        }
    }
}
