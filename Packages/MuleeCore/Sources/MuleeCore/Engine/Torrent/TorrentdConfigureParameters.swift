struct TorrentdConfigureParameters: Codable, Sendable {
    let downloadDir: String
    let listenPort: Int
    let downloadLimit: Int64
    let uploadLimit: Int64
    let maxActiveDownloads: Int
    let maxActiveSeeds: Int
    let dht: Bool
    let lsd: Bool
    let portMapping: Bool
    let encryption: TorrentEncryption
    let diskCacheBytes: Int64
    let blockedClients: [String]

    init(options: EngineOptions, settings: TorrentEngineSettings) {
        // 仅控制写入队列，辅助进程将其限制在 1–256 MiB。
        downloadDir = options.downloadDirectory.path
        listenPort = settings.listenPort
        downloadLimit = options.downloadLimit
        uploadLimit = options.uploadLimit
        maxActiveDownloads = options.maxConcurrentDownloads
        maxActiveSeeds = settings.maxActiveSeeds
        dht = settings.dht
        lsd = settings.lsd
        portMapping = settings.portMapping
        encryption = settings.encryption
        diskCacheBytes = settings.diskCacheBytes
        blockedClients = settings.blockedClients
    }
}
