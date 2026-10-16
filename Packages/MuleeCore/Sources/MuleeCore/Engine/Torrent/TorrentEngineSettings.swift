import Darwin

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

    public var skipJunkFiles: Bool
    public var junkFilePatterns: [String]
    public var seedTimeLimitMinutes: Int
    public var seedInactiveLimitMinutes: Int
    public var privateMinSeedMinutes: Int
    public var ipBlocklistPath: String

    public static let defaultJunkFilePatterns = [
        "*.url", "*.lnk", "*padding_file*", "_____padding_file_*", "*.!ut",
        "*最新地址*.txt", "*广告*.txt", "*最新地址*.html", "*广告*.html", "*.mht"
    ]

    /// BEP 20 确认 XL 为 Xunlei；不推断其他未确认的客户端前缀。
    /// https://www.bittorrent.org/beps/bep_0020.html
    public static let defaultBlockedClients = ["-XL"]

    /// 与 daemon 使用相同的通配规则，供添加面板预选；用户确认后的显式优先级可覆盖它。
    public func isJunkFile(path: String) -> Bool {
        guard skipJunkFiles else { return false }
        let name = String(path.split(separator: "/").last ?? Substring(path))
        return junkFilePatterns.contains { pattern in
            pattern.withCString { rule in
                name.withCString { file in fnmatch(rule, file, FNM_CASEFOLD) == 0 }
            }
        }
    }

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
        blockedClients: [String] = [],
        skipJunkFiles: Bool = true,
        junkFilePatterns: [String] = Self.defaultJunkFilePatterns,
        seedTimeLimitMinutes: Int = 0,
        seedInactiveLimitMinutes: Int = 0,
        privateMinSeedMinutes: Int = 0,
        ipBlocklistPath: String = ""
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
        self.skipJunkFiles = skipJunkFiles
        self.junkFilePatterns = junkFilePatterns
        self.seedTimeLimitMinutes = seedTimeLimitMinutes
        self.seedInactiveLimitMinutes = seedInactiveLimitMinutes
        self.privateMinSeedMinutes = privateMinSeedMinutes
        self.ipBlocklistPath = ipBlocklistPath
    }
}
