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

    init(options: EngineOptions, settings: TorrentEngineSettings) {
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
    }
}
