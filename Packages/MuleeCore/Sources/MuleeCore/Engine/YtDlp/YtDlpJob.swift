import Foundation

struct YtDlpJob: Codable, Sendable {
    let id: String
    let url: URL
    let site: VideoSite
    let directory: URL
    var name: String
    var playlistIndex: Int?
    var playlistTitle: String?
    var playlistFilenamePrefix: String?
    var formatID: String?
    var outputOptions: YtDlpTaskOptions?
    var formatVideoOnly: Bool?
    var status: TaskStatus = .queued
    var totalBytes: Int64?
    var receivedBytes: Int64 = 0
    var savePath: URL?
    var errorMessage: String?
    var isFileWriteFailure: Bool?
    var retried = false
    /// 完成后去掉任务前缀的文件名（成品与字幕、弹幕），删除任务时据此找到文件。旧记录没有这个字段。
    var finalFiles: [String]?

    func snapshot(progress: YtDlpProgress?) -> EngineTaskSnapshot {
        EngineTaskSnapshot(
            engineTaskID: id, name: name,
            totalBytes: progress?.totalBytes ?? totalBytes,
            receivedBytes: progress?.receivedBytes ?? receivedBytes,
            downloadRate: status == .downloading ? (progress?.rate ?? 0) : 0,
            uploadRate: 0, status: status, connections: status == .downloading ? 1 : 0,
            savePath: savePath, sourceURL: url, errorMessage: errorMessage,
            writeDirectories: [directory], isFileWriteFailure: isFileWriteFailure == true
        )
    }
}
