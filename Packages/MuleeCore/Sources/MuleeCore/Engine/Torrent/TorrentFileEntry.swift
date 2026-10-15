/// BT 任务中的一个文件，path 为种子内的相对路径。
public struct TorrentFileEntry: Codable, Sendable, Hashable, Identifiable {
    public let index: Int
    public let path: String
    public let size: Int64
    public let done: Int64
    public let priority: Int

    public var id: Int { index }

    public init(index: Int, path: String, size: Int64, done: Int64 = 0, priority: Int = 4) {
        self.index = index
        self.path = path
        self.size = size
        self.done = done
        self.priority = priority
    }
}
