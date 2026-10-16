import Foundation

/// 路由器报告的 IPv4 证据；发现失败和无效地址均不等同于没有公网地址。
public enum RouterWANIPv4Status: Sendable, Equatable {
    case unknown
    case noPublicIPv4
    case publicIPv4
}

public enum RouterWANIPv4 {
    public static let maximumXMLBytes = 65_536
    public static let maximumSSDPBytes = 8_192

    public struct Service: Sendable, Equatable {
        public let controlURL: URL
        public let type: String
    }

    public static func status(address: String?) -> RouterWANIPv4Status {
        guard let address, let ip = ipv4(address) else { return .unknown }
        if isPrivate(ip) || ip & 0xFFC00000 == 0x64400000 { return .noPublicIPv4 }
        // 未配置、回环、链路本地、测试和保留地址不能作为公网证据。
        guard ip >> 24 != 0, ip >> 24 != 127, ip >> 24 < 224,
              ip & 0xFFFF0000 != 0xA9FE0000,
              ip & 0xFFFFFF00 != 0xC0000000,
              ip & 0xFFFFFF00 != 0xC0000200,
              ip & 0xFFFE0000 != 0xC6120000,
              ip & 0xFFFFFF00 != 0xC6336400,
              ip & 0xFFFFFF00 != 0xCB007100,
              ip & 0xFFFFFF00 != 0xC0586300 else { return .unknown }
        return .publicIPv4
    }

    /// 仅允许物理接口所在网段的默认网关，且禁止域名、凭据及重定向目标。
    public static func localURL(_ url: URL, localIP: String, mask: String, gateway: String) -> Bool {
        guard url.scheme?.lowercased() == "http", url.user == nil, url.password == nil,
              url.fragment == nil, let host = url.host, host == gateway,
              let router = ipv4(host), isPrivate(router),
              let local = ipv4(localIP), let netmask = ipv4(mask),
              netmask != 0, (~netmask & (~netmask &+ 1)) == 0,
              local != router, local & netmask == router & netmask,
              router & ~netmask != 0, router & ~netmask != ~netmask,
              (1...65535).contains(url.port ?? 80) else { return false }
        return true
    }

    public static func ssdpLocation(_ data: Data, localIP: String, mask: String, gateway: String) -> URL? {
        guard data.count <= maximumSSDPBytes, let text = String(data: data, encoding: .utf8),
              !text.contains("\0"), text.hasSuffix("\r\n\r\n") else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard lines.first == "HTTP/1.1 200 OK" else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            guard let separator = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { return nil }
            let key = line[..<separator].lowercased()
            guard headers[key] == nil else { return nil }
            headers[key] = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        }
        guard ["upnp:rootdevice", "urn:schemas-upnp-org:device:InternetGatewayDevice:1",
               "urn:schemas-upnp-org:device:InternetGatewayDevice:2"].contains(headers["st"]),
              let value = headers["location"], let url = URL(string: value),
              localURL(url, localIP: localIP, mask: mask, gateway: gateway) else { return nil }
        return url
    }

    public static func services(_ data: Data, location: URL, localIP: String, mask: String, gateway: String) -> [Service] {
        guard localURL(location, localIP: localIP, mask: mask, gateway: gateway),
              let root = parse(data), root.name == "root",
              root.namespace == "urn:schemas-upnp-org:device-1-0" else { return [] }
        let devices = root.descendants(named: "device").filter {
            ["urn:schemas-upnp-org:device:InternetGatewayDevice:1",
             "urn:schemas-upnp-org:device:InternetGatewayDevice:2"].contains($0.child("deviceType")?.text)
        }
        guard devices.count == 1 else { return [] }
        let bases = root.children.filter { $0.name == "URLBase" }
        guard bases.count <= 1 else { return [] }
        let base: URL
        if let value = bases.first?.text {
            guard let url = URL(string: value), localURL(url, localIP: localIP, mask: mask, gateway: gateway) else { return [] }
            base = url
        } else {
            base = location
        }
        return devices[0].descendants(named: "service").compactMap { node in
            guard let type = node.child("serviceType")?.text,
                  ["WANIPConnection", "WANPPPConnection"].contains(where: {
                      type == "urn:schemas-upnp-org:service:\($0):1" || type == "urn:schemas-upnp-org:service:\($0):2"
                  }),
                  let path = node.child("controlURL")?.text,
                  let url = URL(string: path, relativeTo: base)?.absoluteURL,
                  localURL(url, localIP: localIP, mask: mask, gateway: gateway) else { return nil }
            return Service(controlURL: url, type: type)
        }
    }

    public static func externalAddress(_ data: Data, serviceType: String) -> String? {
        guard let root = parse(data), root.name == "Envelope",
              root.namespace == "http://schemas.xmlsoap.org/soap/envelope/",
              let body = root.child("Body"), body.namespace == root.namespace,
              body.children.count == 1, let response = body.children.first,
              response.name == "GetExternalIPAddressResponse", response.namespace == serviceType,
              let address = response.child("NewExternalIPAddress"), address.children.isEmpty,
              ipv4(address.text) != nil else { return nil }
        return address.text
    }

    private static func ipv4(_ value: String) -> UInt32? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var result: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  part.count == 1 || part.first != "0", let byte = UInt8(part) else { return nil }
            result = (result << 8) | UInt32(byte)
        }
        return result
    }

    private static func isPrivate(_ ip: UInt32) -> Bool {
        ip & 0xFF000000 == 0x0A000000 || ip & 0xFFF00000 == 0xAC100000 || ip & 0xFFFF0000 == 0xC0A80000
    }

    private static func parse(_ data: Data) -> XMLNode? {
        guard data.count <= maximumXMLBytes, let text = String(data: data, encoding: .utf8),
              !text.contains("\0"), !text.localizedCaseInsensitiveContains("<!DOCTYPE"),
              !text.localizedCaseInsensitiveContains("<!ENTITY") else { return nil }
        let delegate = XMLReader()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = delegate
        guard parser.parse(), !delegate.invalid else { return nil }
        return delegate.root
    }
}

private final class XMLNode {
    let name: String
    let namespace: String?
    var text = ""
    var children: [XMLNode] = []

    init(name: String, namespace: String?) {
        self.name = name
        self.namespace = namespace
    }

    func child(_ name: String) -> XMLNode? {
        let matches = children.filter { $0.name == name }
        return matches.count == 1 ? matches[0] : nil
    }

    func descendants(named name: String) -> [XMLNode] {
        children.flatMap { ($0.name == name ? [$0] : []) + $0.descendants(named: name) }
    }
}

private final class XMLReader: NSObject, XMLParserDelegate {
    var root: XMLNode?
    var stack: [XMLNode] = []
    var count = 0
    var invalid = false

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        count += 1
        guard stack.count < 32, count <= 1024 else {
            invalid = true
            parser.abortParsing()
            return
        }
        let node = XMLNode(name: name, namespace: namespaceURI)
        if let parent = stack.last { parent.children.append(node) } else { root = node }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        stack.last?.text = stack.last?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        stack.removeLast()
    }
}
