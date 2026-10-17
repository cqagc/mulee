import Foundation

public struct HTTPProxyConfiguration: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public enum Mode: String, CaseIterable, Sendable {
        case system
        case off
        case manual
    }
    public let mode: Mode
    public let url: URL?
    public let noProxy: [String]
    public let unsupportedReason: String?
    public let credential: HTTPCredentialStore.Credential?

    public init(
        mode: Mode = .system, manualURL: String = "", system: SystemProxyReader.Snapshot = SystemProxyReader.read(),
        credential: HTTPCredentialStore.Credential? = nil, environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.mode = mode
        let manual = Self.manualURL(manualURL)
        url = mode == .system ? system.url : mode == .manual ? manual : nil
        unsupportedReason = mode == .system ? system.unsupportedReason
            : mode == .manual && manual == nil ? "代理地址无效，当前直连；请输入 http://主机:端口。" : nil
        self.credential = mode == .off ? nil : credential
        let bypass = ["localhost", "127.0.0.1", "::1"] + (mode == .system ? system.exceptions : [])
            + [environment["no_proxy"], environment["NO_PROXY"]].compactMap { $0 }.flatMap { $0.components(separatedBy: ",") }
        var seen = Set<String>()
        noProxy = bypass.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.contains(where: { $0.isNewline || $0 == "\0" }) && seen.insert($0).inserted }
    }

    public static func current() -> Self {
        let defaults = UserDefaults.standard
        let mode = Mode(rawValue: defaults.string(forKey: "network.httpProxyMode") ?? "") ?? .system
        let value = defaults.string(forKey: "network.httpProxyURL") ?? ""
        let system = SystemProxyReader.read()
        let configuration = Self(mode: mode, manualURL: value, system: system)
        let credential = configuration.url?.host.flatMap { try? HTTPCredentialStore.load(host: $0, service: HTTPCredentialStore.proxyService) }
        return Self(mode: mode, manualURL: value, system: system, credential: credential)
    }

    public static func manualURL(_ value: String) -> URL? {
        guard !value.contains(where: { $0.isWhitespace || $0 == "\0" }),
              var components = URLComponents(string: value), components.scheme?.lowercased() == "http",
              let host = components.host, !host.isEmpty, let port = components.port, (1...65535).contains(port),
              components.path.isEmpty || components.path == "/", components.query == nil, components.fragment == nil else { return nil }
        components.user = nil
        components.password = nil
        components.path = ""
        return components.url
    }

    public static func redacted(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?i)(https?://)[^\s/]+@"#, with: "$1***@", options: .regularExpression)
    }

    public var description: String { url?.absoluteString ?? "直连" }
    public var debugDescription: String { description }

    var aria2Options: [String: String] {
        ["all-proxy": url?.absoluteString ?? "", "no-proxy": noProxy.map { $0.hasPrefix("*.") ? String($0.dropFirst()) : $0 }.joined(separator: ","),
         "all-proxy-user": credential?.username ?? "", "all-proxy-passwd": credential?.password ?? ""]
    }

    public func proxyArguments() -> [String] {
        switch mode {
        case .system: return []
        case .off: return ["--proxy", ""]
        case .manual:
            guard let url else { return ["--proxy", ""] }
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.user = credential?.username
            components?.password = credential?.password
            return ["--proxy", components?.url?.absoluteString ?? url.absoluteString]
        }
    }

    public var sessionProxyDictionary: [AnyHashable: Any] {
        guard let url, let host = url.host, let port = url.port else { return [:] }
        let dictionary: [AnyHashable: Any] = ["HTTPEnable": 1, "HTTPProxy": host, "HTTPPort": port,
                                          "HTTPSEnable": 1, "HTTPSProxy": host, "HTTPSPort": port,
                                          "ExceptionsList": noProxy, "ExcludeSimpleHostnames": 1]
        return dictionary
    }
}
