/// BT 专用设置，与 EngineOptions 一起完整下发。
public struct TorrentEngineSettings: Sendable, Hashable {
    public var listenPort: Int
    public var dht: Bool
    public var lsd: Bool
    public var portMapping: Bool
    public var encryption: TorrentEncryption
    public var maxActiveSeeds: Int
    public var seedingAction: TorrentSeedingAction
    public var exemptPrivateTorrents: Bool
    /// libtorrent 2.0 待写入磁盘队列上限；读缓存由系统管理。
    public var diskCacheBytes: Int64
    /// 空列表关闭屏蔽；以连字符开头匹配 peer ID，否则匹配客户端名称前缀。
    public var blockedClients: [String]

    /// BEP 20 确认 XL 为 Xunlei；不推断其他未确认的客户端前缀。
    /// https://www.bittorrent.org/beps/bep_0020.html
    public static let defaultBlockedClients = ["-XL"]

    public init(
        listenPort: Int = 6881,
        dht: Bool = true,
        lsd: Bool = true,
        portMapping: Bool = true,
        encryption: TorrentEncryption = .prefer,
        maxActiveSeeds: Int = 5,
        seedingAction: TorrentSeedingAction = .stop,
        exemptPrivateTorrents: Bool = true,
        diskCacheBytes: Int64 = 16 * 1_024 * 1_024,
        blockedClients: [String] = []
    ) {
        self.listenPort = listenPort
        self.dht = dht
        self.lsd = lsd
        self.portMapping = portMapping
        self.encryption = encryption
        self.maxActiveSeeds = maxActiveSeeds
        self.seedingAction = seedingAction
        self.exemptPrivateTorrents = exemptPrivateTorrents
        self.diskCacheBytes = diskCacheBytes
        self.blockedClients = blockedClients
    }
}
