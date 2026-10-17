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
        let reason: String? = pac ? "不支持自动代理脚本（PAC），当前直连；请改用 HTTP 代理。"
            : socks ? "aria2 只支持 HTTP 代理，当前系统仅设置了 SOCKS 代理，因此使用直连。" : nil
        return Snapshot(url: nil, exceptions: exceptions, unsupportedReason: reason)
    }
}
