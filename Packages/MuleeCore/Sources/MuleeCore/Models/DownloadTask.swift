import Foundation

/// 下载列表里的一个任务。值类型，由引擎层更新后整体替换。
public struct DownloadTask: Identifiable, Sendable, Hashable, Codable {
    public enum PauseReason: String, Sendable, Hashable, Codable {
        case diskSpace
        case volumeUnavailable
        case systemSleep
        case schedule
    }

    /// 可选字段使旧版历史仍可解码；用户暂停不会被磁盘恢复逻辑接管。
    public var tags: [String]?
    public var fileBookmark: Data?
    public var fileMissing: Bool?
    public var deletedAt: Date?
    public var lastProgressAt: Date?
    public var pauseReason: PauseReason?
    public var writeDirectories: [URL]?
    public let id: UUID
    /// 显示名（通常是文件名或视频标题）。
    public var name: String
    /// 主文件扩展名，用于取系统文件图标；文件夹或多文件任务为 nil。
    public var fileExtension: String?
    public var kind: TaskKind
    public var status: TaskStatus
    /// 文件总大小（字节）；未知时为 nil（例如磁力链接还没拿到元数据）。
    public var totalBytes: Int64?
    /// 已收到的字节数。
    public var receivedBytes: Int64
    /// 当前下载速度（字节/秒）。
    public var downloadRate: Int64
    /// 当前上传速度（字节/秒）。
    public var uploadRate: Int64
    /// 预计剩余时间；未知时为 nil。
    public var estimatedTimeRemaining: Duration?
    /// 完成时间；未完成时为 nil。
    public var completedAt: Date?
    public var detail: TaskDetail
    public var postDownload: PostDownloadInfo
    /// 原始链接（用于「复制链接」）。
    public var sourceLink: String
    /// 浏览器提供的来源页面；旧任务记录没有此字段时为 nil。
    public var sourcePageURL: URL?
    /// 历史中的上下文不包含 Cookie；有 Cookie 时按本任务 ID 从钥匙串读取。
    public var requestContext: DownloadRequestContext?
    public var hasHTTPCredentials: Bool?
    public var hasRequestCookie: Bool?
    public var httpIdentity: HTTPResourceIdentity?
    public var videoIdentity: String?
    public var httpValidationError: String?
    public var videoOptions: YtDlpTaskOptions?
    public var checksum: DownloadChecksum?
    public var checksumVerification: ChecksumVerification?
    /// 引擎内部的任务标识（例如 aria2 的 GID）；还没交给引擎时为 nil。
    public var engineTaskID: String?
    /// 文件在磁盘上的完整路径；引擎还没确定文件名时为 nil。
    public var savePath: URL?
    /// 引擎报告的错误信息（status 为 .failed 时显示）。
    public var errorMessage: String?

    public init(
        id: UUID = UUID(),
        name: String,
        fileExtension: String?,
        kind: TaskKind,
        status: TaskStatus,
        totalBytes: Int64?,
        receivedBytes: Int64,
        downloadRate: Int64 = 0,
        uploadRate: Int64 = 0,
        estimatedTimeRemaining: Duration? = nil,
        completedAt: Date? = nil,
        detail: TaskDetail,
        postDownload: PostDownloadInfo,
        sourceLink: String,
        sourcePageURL: URL? = nil,
        engineTaskID: String? = nil,
        savePath: URL? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.name = name
        self.fileExtension = fileExtension
        self.kind = kind
        self.status = status
        self.totalBytes = totalBytes
        self.receivedBytes = receivedBytes
        self.downloadRate = downloadRate
        self.uploadRate = uploadRate
        self.estimatedTimeRemaining = estimatedTimeRemaining
        self.completedAt = completedAt
        self.detail = detail
        self.postDownload = postDownload
        self.sourceLink = sourceLink
        self.sourcePageURL = sourcePageURL
        self.engineTaskID = engineTaskID
        self.savePath = savePath
        self.errorMessage = errorMessage
    }

    /// 下载进度 0...1；总大小未知时为 nil。
    public var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, Double(receivedBytes) / Double(totalBytes))
    }
}
