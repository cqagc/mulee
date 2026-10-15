/// 侧边栏底部与设置·网络页显示的网络状态。
public struct NetworkStatus: Sendable, Hashable, Codable {
    /// 电驴服务器分配的 ID 类型。
    public enum Ed2kID: String, Sendable, Hashable, Codable {
        case high
        case low
        case disconnected
    }

    /// Kad 网络状态。
    public enum KadState: String, Sendable, Hashable, Codable {
        /// 已连接，外部可以主动连入。
        case open
        /// 已连接，但外部无法主动连入。
        case firewalled
        case disconnected
    }

    public var ed2kID: Ed2kID
    public var kad: KadState
    /// BT 端口是否可从外部连入；nil 表示尚未检测。
    public var bittorrentPortReachable: Bool?
    /// P2P 流量是否经过代理（检测到出口 IP 与本机宽带不一致）。
    public var p2pRoutedThroughProxy: Bool
    /// P2P 出口 IP（界面上只显示前两段）。
    public var p2pExitIP: String?
    /// UPnP / NAT-PMP 端口映射是否成功；nil 表示未启用。
    public var portMappingSucceeded: Bool?

    public init(ed2kID: Ed2kID, kad: KadState, bittorrentPortReachable: Bool?, p2pRoutedThroughProxy: Bool, p2pExitIP: String?, portMappingSucceeded: Bool?) {
        self.ed2kID = ed2kID
        self.kad = kad
        self.bittorrentPortReachable = bittorrentPortReachable
        self.p2pRoutedThroughProxy = p2pRoutedThroughProxy
        self.p2pExitIP = p2pExitIP
        self.portMappingSucceeded = portMappingSucceeded
    }
}
