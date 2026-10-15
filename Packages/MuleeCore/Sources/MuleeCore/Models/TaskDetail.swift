/// 每种任务类型独有的信息。
public enum TaskDetail: Sendable, Hashable, Codable {
    /// HTTP：分段线程数。
    case http(connections: Int)
    /// BT：文件总数、已选择的文件数、已连接节点数、分享率（已上传 / 文件大小）。
    case bittorrent(fileCount: Int, selectedFileCount: Int, peerCount: Int, shareRatio: Double)
    /// 电驴：文件哈希与长尾等待信息。
    case ed2k(hash: String, longTail: LongTailInfo)
    /// 视频：站点、画质描述、是否把弹幕转成 ASS 字幕。
    case video(site: VideoSite, quality: String, danmakuToASS: Bool)
}
