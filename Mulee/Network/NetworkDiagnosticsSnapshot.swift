import Darwin
import Foundation

/// 探测证据。nil 表示探测未完成或不可用，不把未知当作直连。
nonisolated struct NetworkDiagnosticsSnapshot: Sendable, Equatable {
    enum ProxyKind: Sendable, CaseIterable {
        case unknown
        case none
        case system
        case tunnel
    }

    var routedThroughTunnel: Bool?
    var trackerAddresses: [String]?
    var systemProxyEnabled: Bool?
    var localIP: String?
    var subnetMask: String?
    var gateway: String?

    static let unknown = Self()

    var usesFakeIP: Bool {
        trackerAddresses?.contains(where: Self.isFakeIP) == true
    }

    var proxyKind: ProxyKind {
        if routedThroughTunnel == true || usesFakeIP { return .tunnel }
        guard routedThroughTunnel == false, trackerAddresses != nil,
              let systemProxyEnabled else { return .unknown }
        return systemProxyEnabled ? .system : .none
    }

    var isOnGatewaySubnet: Bool? {
        Self.sameSubnet(localIP: localIP, mask: subnetMask, gateway: gateway)
    }

    static func isFakeIP(_ address: String) -> Bool {
        guard let ip = ipv4(address) else { return false }
        return ip & 0xFFFE0000 == 0xC6120000
    }

    static func sameSubnet(localIP: String?, mask: String?, gateway: String?) -> Bool? {
        guard let localIP, let mask, let gateway,
              let local = ipv4(localIP), let mask = ipv4(mask), let router = ipv4(gateway),
              mask != 0, (~mask & (~mask &+ 1)) == 0 else { return nil }
        return local & mask == router & mask
    }

    private static func ipv4(_ value: String) -> UInt32? {
        var address = in_addr()
        guard inet_pton(AF_INET, value, &address) == 1 else { return nil }
        return UInt32(bigEndian: address.s_addr)
    }
}
