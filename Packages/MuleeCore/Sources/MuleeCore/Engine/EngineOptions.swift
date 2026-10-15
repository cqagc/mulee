import Foundation

/// 下发给下载引擎的全局设置。来自设置窗口，变化时整体重新下发。
public struct EngineOptions: Sendable, Hashable {
    /// 默认保存目录。
    public var downloadDirectory: URL
    /// 同时进行的任务数。
    public var maxConcurrentDownloads: Int
    /// HTTP 每个任务对同一服务器的最大连接数（aria2 上限 16）。
    public var connectionsPerServer: Int
    /// 全局下载限速（字节/秒），0 表示不限速。
    public var downloadLimit: Int64
    /// 全局上传限速（字节/秒），0 表示不限速。
    public var uploadLimit: Int64
    /// 磁盘缓存（MB）：先在内存里攒成大块再写盘。
    public var diskCacheMegabytes: Int

    public init(
        downloadDirectory: URL,
        maxConcurrentDownloads: Int = 5,
        connectionsPerServer: Int = 8,
        downloadLimit: Int64 = 0,
        uploadLimit: Int64 = 0,
        diskCacheMegabytes: Int = 128
    ) {
        self.downloadDirectory = downloadDirectory
        self.maxConcurrentDownloads = maxConcurrentDownloads
        self.connectionsPerServer = connectionsPerServer
        self.downloadLimit = downloadLimit
        self.uploadLimit = uploadLimit
        self.diskCacheMegabytes = diskCacheMegabytes
    }
}
