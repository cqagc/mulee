/// 添加结果保留自动跳过的文件，供调用方展示并允许重新勾选。
public struct TorrentdAddResult: Codable, Sendable {
    public let id: String
    public let name: String
    public let duplicate: Bool
    public let skippedFiles: [TorrentSkippedFile]?
}

/// 自动过滤文件在种子中的索引和相对路径。
public struct TorrentSkippedFile: Codable, Sendable, Equatable {
    public let index: Int
    public let path: String
}
