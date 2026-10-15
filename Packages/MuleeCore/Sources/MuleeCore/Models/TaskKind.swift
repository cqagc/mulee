/// 下载任务的协议类型。每种类型对应一个下载引擎。
public enum TaskKind: String, Sendable, Hashable, CaseIterable, Codable {
    /// HTTP / HTTPS / FTP，引擎为 aria2。迅雷链接解析后也归为此类（或解析出的其他类型）。
    case http
    /// BT 种子与磁力链接，引擎为 libtorrent。
    case bittorrent
    /// 电驴 ed2k 链接，引擎为 amuled。
    case ed2k
    /// 视频站页面，引擎为 yt-dlp。
    case video
}
