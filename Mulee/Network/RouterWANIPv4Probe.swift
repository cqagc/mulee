import Darwin
import Foundation
import MuleeCore

/// 只发送发现和读取请求，不申请映射。UDP 固定从物理接口发送，避免 TUN 抢走 SSDP。
nonisolated struct RouterWANIPv4Probe {
    @concurrent
    func probe(interface: String?, localIP: String?, mask: String?, gateway: String?) async -> String? {
        guard let interface, let localIP, let mask, let gateway,
              let gatewayURL = URL(string: "http://\(gateway)/"),
              RouterWANIPv4.localURL(gatewayURL, localIP: localIP, mask: mask, gateway: gateway),
              !Task.isCancelled else { return nil }
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        let locations = discover(interface: interface, localIP: localIP, mask: mask, gateway: gateway)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0,
                                                    "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0]
        configuration.timeoutIntervalForRequest = 0.7
        configuration.timeoutIntervalForResource = 0.7
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: RejectRouterRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var addresses = Set<String>()
        for location in locations {
            guard !Task.isCancelled, ContinuousClock.now < deadline else { break }
            guard let description = await read(URLRequest(url: location), session: session) else { continue }
            let services = RouterWANIPv4.services(description, location: location, localIP: localIP, mask: mask, gateway: gateway)
            for service in services.prefix(2) {
                guard !Task.isCancelled, ContinuousClock.now < deadline else { break }
                var request = URLRequest(url: service.controlURL)
                request.httpMethod = "POST"
                request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
                request.setValue("\"\(service.type)#GetExternalIPAddress\"", forHTTPHeaderField: "SOAPAction")
                request.httpBody = Data("""
                <?xml version="1.0"?>
                <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
                  <s:Body><u:GetExternalIPAddress xmlns:u="\(service.type)"/></s:Body>
                </s:Envelope>
                """.utf8)
                guard let data = await read(request, session: session),
                      let address = RouterWANIPv4.externalAddress(data, serviceType: service.type),
                      RouterWANIPv4.status(address: address) != .unknown else { continue }
                addresses.insert(address)
            }
        }
        return addresses.count == 1 ? addresses.first : nil
    }

    private func read(_ request: URLRequest, session: URLSession) async -> Data? {
        do {
            var request = request
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  response.expectedContentLength <= RouterWANIPv4.maximumXMLBytes else { return nil }
            var data = Data()
            for try await byte in bytes {
                guard data.count < RouterWANIPv4.maximumXMLBytes, !Task.isCancelled else { return nil }
                data.append(byte)
            }
            return data
        } catch {
            return nil
        }
    }

    private func discover(interface: String, localIP: String, mask: String, gateway: String) -> [URL] {
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { return [] }
        defer { close(descriptor) }
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { return [] }
        var index = if_nametoindex(interface)
        var local = in_addr()
        guard index != 0, inet_pton(AF_INET, localIP, &local) == 1,
              setsockopt(descriptor, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout.size(ofValue: index))) == 0,
              setsockopt(descriptor, IPPROTO_IP, IP_MULTICAST_IF, &local, socklen_t(MemoryLayout.size(ofValue: local))) == 0 else { return [] }
        var source = sockaddr_in()
        source.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        source.sin_family = sa_family_t(AF_INET)
        source.sin_addr = local
        let bound = withUnsafePointer(to: &source) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { return [] }
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = UInt16(1900).bigEndian
        inet_pton(AF_INET, "239.255.255.250", &destination.sin_addr)
        for target in ["urn:schemas-upnp-org:device:InternetGatewayDevice:1",
                       "urn:schemas-upnp-org:device:InternetGatewayDevice:2", "upnp:rootdevice"] {
            let query = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: \(target)\r\n\r\n"
            query.withCString { buffer in
                _ = withUnsafePointer(to: &destination) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(descriptor, buffer, query.utf8.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(1200))
        var locations: [URL] = []
        var buffer = [UInt8](repeating: 0, count: RouterWANIPv4.maximumSSDPBytes + 1)
        while ContinuousClock.now < deadline, !Task.isCancelled, locations.count < 2 {
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&pollDescriptor, 1, 50) > 0 else { continue }
            guard pollDescriptor.revents & Int16(POLLIN) != 0 else { break }
            var sender = sockaddr_in()
            var size = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &sender) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(descriptor, &buffer, buffer.count, 0, $0, &size) }
            }
            var router = in_addr()
            inet_pton(AF_INET, gateway, &router)
            guard count > 0, sender.sin_addr.s_addr == router.s_addr,
                  let url = RouterWANIPv4.ssdpLocation(Data(buffer.prefix(count)), localIP: localIP, mask: mask, gateway: gateway),
                  !locations.contains(url) else { continue }
            locations.append(url)
        }
        return locations
    }
}

nonisolated private final class RejectRouterRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
