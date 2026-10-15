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

    public init(
        listenPort: Int = 6881,
        dht: Bool = true,
        lsd: Bool = true,
        portMapping: Bool = true,
        encryption: TorrentEncryption = .prefer,
        maxActiveSeeds: Int = 5,
        seedingAction: TorrentSeedingAction = .stop,
        exemptPrivateTorrents: Bool = true
    ) {
        self.listenPort = listenPort
        self.dht = dht
        self.lsd = lsd
        self.portMapping = portMapping
        self.encryption = encryption
        self.maxActiveSeeds = maxActiveSeeds
        self.seedingAction = seedingAction
        self.exemptPrivateTorrents = exemptPrivateTorrents
    }
}
