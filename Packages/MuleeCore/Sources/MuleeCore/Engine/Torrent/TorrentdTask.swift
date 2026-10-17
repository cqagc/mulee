struct TorrentdTask: Codable, Sendable {
    let id: String
    let name: String
    let savePath: String
    let contentPath: String?
    let hasMetadata: Bool
    let state: String
    let paused: Bool
    let totalWanted: Int64
    let totalWantedDone: Int64
    let progress: Double
    let downloadRate: Int64
    let uploadRate: Int64
    let allTimeDownload: Int64
    let allTimeUpload: Int64
    let ratio: Double
    let numPeers: Int
    let numSeeds: Int
    let listPeers: Int
    let listSeeds: Int
    let fileCount: Int
    let selectedFileCount: Int
    let isPrivate: Bool
    let uploadLimit: Int64
    let error: String?
    let source: String?
    let addedAt: Int64
    let completedAt: Int64?
    let eta: Int64?
    let queued: Bool
    let isFinished: Bool?
    let sequentialDownload: Bool?
    let firstLastPriority: Bool?
    let diagnostics: TorrentDiagnostics?
    let seedTimeSeconds: Int64?
    let seedInactiveSeconds: Int64?
    var userDownloadLimit: Int64? = nil
    var userUploadLimit: Int64? = nil
    var policyUploadLimit: Int64? = nil
    let skippedFiles: [TorrentSkippedFile]?

    /// 恢复校验、缺少元数据或扩大文件选择后，不应用做种策略。
    var canApplySeedingPolicy: Bool {
        hasMetadata && isFinished == true && (state == "seeding" || state == "finished")
            && totalWanted > 0 && totalWantedDone >= totalWanted && selectedFileCount > 0
    }
}
