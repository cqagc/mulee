import Foundation

/// 引擎报告的一个任务的当前状态。App 层按 engineTaskID 合并进 DownloadTask。
public struct EngineTaskSnapshot: Sendable, Hashable, Identifiable {
    /// 引擎内部的任务标识（aria2 的 GID）。
    public var engineTaskID: String
    /// 显示名：已知文件名时为文件名，否则为 URL 最后一段。
    public var name: String
    public var totalBytes: Int64?
    public var receivedBytes: Int64
    public var downloadRate: Int64
    public var uploadRate: Int64
    /// 只会是 downloading / queued / paused / completed / failed 之一。
    public var status: TaskStatus
    /// 当前活跃连接数。
    public var connections: Int
    /// 文件完整路径；引擎还没确定文件名时为 nil。
    public var savePath: URL?
    /// 下载来源 URL。
    public var sourceURL: URL?
    /// 出错时的错误说明（已转成用户能看懂的中文，原始错误码附在末尾）。
    public var errorMessage: String?

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
        errorMessage: String?
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
        self.sourceURL = sourceURL
        self.errorMessage = errorMessage
    }
}
