import CFNetwork
import Foundation

public enum SystemProxyReader {
    public struct Snapshot: Sendable, Equatable {
        public let url: URL?
        public let exceptions: [String]
        public let unsupportedReason: String?
    }

    public static func read() -> Snapshot {
        parse(CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] ?? [:])
    }

    /// 字典入口让测试不依赖机器的网络设置。
    public static func parse(_ settings: [String: Any]) -> Snapshot {
        let exceptions = settings["ExceptionsList"] as? [String] ?? []
        for prefix in ["HTTPS", "HTTP"] where (settings[prefix + "Enable"] as? NSNumber)?.boolValue == true {
            if let host = settings[prefix + "Proxy"] as? String,
               !host.isEmpty, let port = settings[prefix + "Port"] as? Int, (1...65535).contains(port) {
                var components = URLComponents()
                components.scheme = "http"
                components.host = host
                components.port = port
                if let url = components.url {
                    return Snapshot(url: url, exceptions: exceptions, unsupportedReason: nil)
                }
            }
        }
        let pac = (settings["ProxyAutoConfigEnable"] as? NSNumber)?.boolValue == true
            || (settings["ProxyAutoDiscoveryEnable"] as? NSNumber)?.boolValue == true
        let socks = (settings["SOCKSEnable"] as? NSNumber)?.boolValue == true
        let reason: String? = pac ? String(localized: "HTTP 下载不支持自动代理配置（PAC），现在直连。可以在系统设置里改用 HTTP 代理，或在这里手动填写。", bundle: .module)
            : socks ? String(localized: "HTTP 下载只能使用 HTTP 代理。系统现在只设置了 SOCKS 代理，所以 HTTP 下载直连。", bundle: .module) : nil
        return Snapshot(url: nil, exceptions: exceptions, unsupportedReason: reason)
    }
}
