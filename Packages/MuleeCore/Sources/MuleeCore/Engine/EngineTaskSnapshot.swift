import Foundation

/// 引擎报告的一个任务的当前状态。App 层按 engineTaskID 合并进 DownloadTask。
public struct EngineTaskSnapshot: Sendable, Hashable, Identifiable {
    /// 引擎内部的任务标识（例如 aria2 的 GID、BT 的 info-hash）。
    public var engineTaskID: String
    /// 显示名：已知文件名时为文件名，否则为 URL 最后一段。
    public var name: String
    public var totalBytes: Int64?
    public var receivedBytes: Int64
    public var downloadRate: Int64
    public var uploadRate: Int64
    /// 只会是 downloading / queued / paused / seeding / completed / failed 之一。
    public var status: TaskStatus
    /// 当前活跃连接数。
    public var connections: Int
    /// 文件或多文件任务顶层目录的完整路径；引擎还没确定名称时为 nil。
    public var savePath: URL?
    /// 实际写入的目录；视频尚未确定文件名、电驴临时目录也需要磁盘保护。
    public var writeDirectories: [URL]?
    /// 下载来源 URL。
    public var sourceURL: URL?
    /// 出错时的错误说明（已转成用户能看懂的中文，原始错误码附在末尾）。
    public var errorMessage: String?
    /// 在清洗原始报错前记录写盘错误，卷保护不依赖本地化文案。
    public var isFileWriteFailure: Bool
    public var isControlFileFailure: Bool
    /// 引擎报告的类型专属详情；nil 时保留 App 已有详情。
    public var detail: TaskDetail?
    /// 引擎记录的完成时间，BT 做种期间也保留。
    public var completedAt: Date?

    public static func describesFileWriteFailure(_ message: String) -> Bool {
        let text = message.lowercased()
        return ["failed to write", "write error", "writing", "unable to write", "unable to open for writing",
                "file_error", "io_error", "input/output error", "no such device", "device not configured",
                "read-only file system", "no space left", "disk full", "permission denied", "segment file",
                "no such file or directory", "cannot create", "failed to create", "unable to open file", "file_open", "file_write",
                "errno 2", "errno 5", "errno 6", "errno 19", "errno 28", "errno 30", "control file"].contains(where: text.contains)
    }

    public var id: String { engineTaskID }

    public init(
        engineTaskID: String,
        name: String,
        totalBytes: Int64?,
        receivedBytes: Int64,
        downloadRate: Int64,
        uploadRate: Int64,
        status: TaskStatus,
        connections: Int,
        savePath: URL?,
        sourceURL: URL?,
        errorMessage: String?,
        detail: TaskDetail? = nil,
        completedAt: Date? = nil,
        writeDirectories: [URL]? = nil,
        isFileWriteFailure: Bool = false,
        isControlFileFailure: Bool = false
    ) {
        self.engineTaskID = engineTaskID
        self.name = name
        self.totalBytes = totalBytes
        self.receivedBytes = receivedBytes
        self.downloadRate = downloadRate
        self.uploadRate = uploadRate
        self.status = status
        self.connections = connections
        self.savePath = savePath
        self.writeDirectories = writeDirectories
        self.sourceURL = sourceURL
        self.errorMessage = errorMessage
        self.isFileWriteFailure = isFileWriteFailure
        self.isControlFileFailure = isControlFileFailure
        self.detail = detail
        self.completedAt = completedAt
    }
}
