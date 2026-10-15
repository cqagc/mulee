/// 下载完成后的处理信息：自动解压与文件名编码修复。
public struct PostDownloadInfo: Sendable, Hashable, Codable {
    /// 是否自动解压。
    public var autoExtract: Bool
    /// 命中的解压密码规则名称（例如来源网站）；nil 表示没有命中。
    public var matchedRuleName: String?
    /// 检测到或指定的文件名编码，例如 "Big5"；nil 表示自动检测尚未得出结果。
    public var filenameEncoding: String?
    /// 解压进度 0...1；nil 表示还没开始解压。
    public var extractProgress: Double?

    public init(autoExtract: Bool, matchedRuleName: String? = nil, filenameEncoding: String? = nil, extractProgress: Double? = nil) {
        self.autoExtract = autoExtract
        self.matchedRuleName = matchedRuleName
        self.filenameEncoding = filenameEncoding
        self.extractProgress = extractProgress
    }
}
