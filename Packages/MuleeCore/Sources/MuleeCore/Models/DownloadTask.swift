import Foundation

/// 下载列表里的一个任务。值类型，由引擎层更新后整体替换。
public struct DownloadTask: Identifiable, Sendable, Hashable, Codable {
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
        sourceLink: String
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
    }

    /// 下载进度 0...1；总大小未知时为 nil。
    public var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, Double(receivedBytes) / Double(totalBytes))
    }
}
