import Foundation

/// 下载完成后的处理信息：自动解压与文件名编码修复。
public struct PostDownloadInfo: Sendable, Hashable, Codable {
    public enum ExtractionState: String, Sendable, Hashable, Codable {
        case queued
        case waitingForVolumes
        case extracting
        case succeeded
        case failed
        case cancelled
    }

    /// 是否自动解压。
    public var autoExtract: Bool
    /// 命中的解压密码规则名称（例如来源网站）；nil 表示没有命中。
    public var matchedRuleName: String?
    /// 检测到或指定的文件名编码，例如 "Big5"；nil 表示自动检测尚未得出结果。
    public var filenameEncoding: String?
    /// 解压进度 0...1；nil 表示还没开始解压。
    public var extractProgress: Double?

    /// 可选字段让旧版本 tasks.json 继续正常读取。
    public var extractionState: ExtractionState?
    public var extractionFailure: String?
    public var extractedItems: [URL]?
    public var extractionWarnings: [String]?

    public init(
        autoExtract: Bool,
        matchedRuleName: String? = nil,
        filenameEncoding: String? = nil,
        extractProgress: Double? = nil,
        extractionState: ExtractionState? = nil,
        extractionFailure: String? = nil,
        extractedItems: [URL]? = nil,
        extractionWarnings: [String]? = nil
    ) {
        self.autoExtract = autoExtract
        self.matchedRuleName = matchedRuleName
        self.filenameEncoding = filenameEncoding
        self.extractProgress = extractProgress
        self.extractionState = extractionState
        self.extractionFailure = extractionFailure
        self.extractedItems = extractedItems
        self.extractionWarnings = extractionWarnings
    }
}
