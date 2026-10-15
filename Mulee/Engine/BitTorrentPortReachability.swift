import Foundation

/// 只有出现过连接证据才推导端口状态，空闲会话保持未确认。
struct BitTorrentPortReachability {
    private(set) var startedAt: Date
    private(set) var sawPeers = false
    private(set) var sawIncoming = false

    init(startedAt: Date = .now) {
        self.startedAt = startedAt
    }

    mutating func observePeers(_ connected: Bool) {
        sawPeers = sawPeers || connected
    }

    mutating func observe(incoming: Bool, now: Date = .now) -> Bool? {
        sawIncoming = sawIncoming || incoming
        if sawIncoming { return true }
        if sawPeers, now.timeIntervalSince(startedAt) > 600 { return false }
        return nil
    }
}
