import Foundation

struct YtDlpJob: Codable, Sendable {
    let id: String
    let url: URL
    let site: VideoSite
    let directory: URL
    var name: String
    var status: TaskStatus = .queued
    var totalBytes: Int64?
    var receivedBytes: Int64 = 0
    var savePath: URL?
    var errorMessage: String?
    var retried = false

    func snapshot(progress: YtDlpProgress?) -> EngineTaskSnapshot {
        EngineTaskSnapshot(
            engineTaskID: id, name: name,
            totalBytes: progress?.totalBytes ?? totalBytes,
            receivedBytes: progress?.receivedBytes ?? receivedBytes,
            downloadRate: status == .downloading ? (progress?.rate ?? 0) : 0,
            uploadRate: 0, status: status, connections: status == .downloading ? 1 : 0,
            savePath: savePath, sourceURL: url, errorMessage: errorMessage
        )
    }
}
