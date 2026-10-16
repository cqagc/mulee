/// BT 会话的端口、发现节点与连接情况。
public struct TorrentSessionStatus: Codable, Sendable, Hashable {
    public let listenPort: Int
    public let dhtNodes: Int
    public let hasIncomingConnections: Bool
    public let downloadRate: Int64
    public let uploadRate: Int64
    public let externalAddress: String?
    public var portMappingEnabled: Bool? = nil
    public var portMappings: [PortMappingResult]? = nil
    public var extraPortMappings: [ExtraPortMappingStatus]? = nil
}

/// 希望由 BT 会话代为转发的本机端口；重复端口由辅助进程合并。
public struct ExtraPortMappings: Codable, Sendable, Equatable {
    public var tcp: [Int]
    public var udp: [Int]

    public init(tcp: [Int] = [], udp: [Int] = []) {
        self.tcp = tcp
        self.udp = udp
    }
}

/// 路由器接受映射不代表外部连接已通过；连通性仍以引擎状态为准。
public struct PortMappingResult: Codable, Sendable, Hashable {
    public let transport: String
    public let externalPort: Int
    public let localPort: Int
    public let `protocol`: String
    public let succeeded: Bool
    public let message: String

    public var usesRequestedPort: Bool { succeeded && externalPort == localPort }
}

public struct ExtraPortMappingStatus: Codable, Sendable, Hashable {
    public let `protocol`: String
    public let localPort: Int
    public let results: [PortMappingResult]

    public var succeeded: Bool? {
        if results.contains(where: \.usesRequestedPort) { return true }
        return results.isEmpty ? nil : false
    }
}
