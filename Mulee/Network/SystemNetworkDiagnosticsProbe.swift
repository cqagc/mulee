import CFNetwork
import Darwin
import Foundation
import SystemConfiguration

/// 只读系统路由、接口、代理设置及公开 tracker 的解析结果。
nonisolated struct SystemNetworkDiagnosticsProbe: NetworkDiagnosticsProbing {
    @concurrent
    func probe() async -> NetworkDiagnosticsSnapshot {
        let store = SCDynamicStoreCreate(nil, "Mulee 网络诊断" as CFString, nil, nil)
        let network = store.flatMap(physicalNetwork)
        let local = localAddress(interface: network?.interface)
        return NetworkDiagnosticsSnapshot(
            routedThroughTunnel: tunnelRoute(),
            trackerAddresses: trackerAddresses(),
            systemProxyEnabled: systemProxyEnabled(),
            localIP: local?.ip,
            subnetMask: local?.mask,
            gateway: network?.gateway
        )
    }

    /// TUN 可能成为全局主接口；转发目标必须取实际连接路由器的物理接口。
    private func physicalNetwork(_ store: SCDynamicStore) -> (interface: String, gateway: String?)? {
        if let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
           let interface = global["PrimaryInterface"] as? String, !interface.hasPrefix("utun"),
           localAddress(interface: interface) != nil {
            return (interface, global["Router"] as? String)
        }
        let setup = SCDynamicStoreCopyValue(store, "Setup:/Network/Global/IPv4" as CFString) as? [String: Any]
        let order = setup?["ServiceOrder"] as? [String] ?? []
        let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/.*/IPv4" as CFString) as? [String] ?? []
        let orderedKeys = order.map { "State:/Network/Service/\($0)/IPv4" }
        for key in orderedKeys + keys.sorted() where keys.contains(key) {
            guard let service = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                  let interface = service["InterfaceName"] as? String,
                  !interface.hasPrefix("utun"), interface != "lo0",
                  let gateway = service["Router"] as? String, localAddress(interface: interface) != nil else { continue }
            return (interface, gateway)
        }
        return nil
    }

    private func systemProxyEnabled() -> Bool? {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        return [kCFNetworkProxiesHTTPEnable, kCFNetworkProxiesHTTPSEnable,
                kCFNetworkProxiesProxyAutoConfigEnable, kCFNetworkProxiesProxyAutoDiscoveryEnable]
            .contains { (settings[$0 as String] as? NSNumber)?.boolValue == true }
    }

    private func trackerAddresses() -> [String]? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo("bttracker.debian.org", nil, &hints, &result) == 0, let first = result else {
            return nil
        }
        defer { freeaddrinfo(first) }
        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let entry = cursor {
            if let address = entry.pointee.ai_addr, let ip = numericAddress(address) {
                addresses.append(ip)
            }
            cursor = entry.pointee.ai_next
        }
        return addresses.isEmpty ? nil : addresses
    }

    private func localAddress(interface: String?) -> (ip: String, mask: String)? {
        guard let interface, !interface.hasPrefix("utun") else { return nil }
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(first) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            let item = entry.pointee
            if String(cString: item.ifa_name) == interface,
               let address = item.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
               let netmask = item.ifa_netmask,
               let ip = numericAddress(address), let mask = numericAddress(netmask) {
                return (ip, mask)
            }
            cursor = item.ifa_next
        }
        return nil
    }

    private func numericAddress(_ address: UnsafePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                          nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// 包括代理常用的两条 /1 路由；只有存在 utun 接口并不代表默认流量被接管。
    private func tunnelRoute() -> Bool? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_UNSPEC, NET_RT_DUMP2, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else { return nil }
        var data = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &data, &size, nil, 0) == 0 else { return nil }
        return data.withUnsafeBytes { bytes in
            var offset = 0
            while offset + MemoryLayout<rt_msghdr2>.size <= size {
                let header = bytes.loadUnaligned(fromByteOffset: offset, as: rt_msghdr2.self)
                let length = Int(header.rtm_msglen)
                guard length >= MemoryLayout<rt_msghdr2>.size, offset + length <= size else { return nil }
                var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                if header.rtm_flags & RTF_UP != 0, header.rtm_flags & RTF_IFSCOPE == 0,
                   header.rtm_flags & RTF_HOST == 0,
                   if_indextoname(UInt32(header.rtm_index), &name) != nil,
                   String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).hasPrefix("utun"),
                   isDefaultRoute(bytes, offset: offset, length: length, addresses: header.rtm_addrs) {
                    return true
                }
                offset += length
            }
            return false
        }
    }

    private func isDefaultRoute(_ bytes: UnsafeRawBufferPointer, offset: Int, length: Int, addresses: Int32) -> Bool {
        var cursor = offset + MemoryLayout<rt_msghdr2>.size
        var destination: [UInt8]?
        var mask: [UInt8]?
        for index in 0..<Int(RTAX_MAX) where addresses & (1 << index) != 0 {
            guard cursor + 2 <= offset + length else { return false }
            let count = Int(bytes[cursor])
            guard cursor + count <= offset + length else { return false }
            if index == Int(RTAX_DST) { destination = Array(bytes[cursor..<(cursor + count)]) }
            if index == Int(RTAX_NETMASK) { mask = Array(bytes[cursor..<(cursor + count)]) }
            cursor += max(4, (count + 3) & ~3)
        }
        guard let destination, destination.count >= 2 else { return false }
        let family = Int32(destination[1])
        guard family == AF_INET || family == AF_INET6 else { return false }
        let start = family == AF_INET ? 4 : 8
        let count = family == AF_INET ? 4 : 16
        guard destination.count >= start + count else { return false }
        let network = Array(destination[start..<(start + count)])
        let netmask = (0..<count).map { index -> UInt8 in
            guard let mask, mask.count > start + index else { return 0 }
            return mask[start + index]
        }
        let zero = [UInt8](repeating: 0, count: count)
        var half = zero
        half[0] = 128
        return (network == zero && netmask == zero)
            || ((network == zero || network == half) && netmask == half)
    }
}
