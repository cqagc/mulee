import Foundation

/// 公共 tracker 与订阅地址的验证；WebTorrent 不受当前引擎支持。
public enum PublicTrackerList {
    public static let maximumResponseSize = 512 * 1_024
    public static let maximumTrackers = 2_000
    public static let defaultSubscriptions = """
        https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_best.txt | https://cdn.jsdelivr.net/gh/ngosang/trackerslist@master/trackers_best.txt | https://ngosang.github.io/trackerslist/trackers_best.txt
        https://raw.githubusercontent.com/XIU2/TrackersListCollection/master/best.txt | https://cdn.jsdelivr.net/gh/XIU2/TrackersListCollection@master/best.txt
        """

    public static func parse(_ text: String) -> [String] {
        var seen: Set<String> = []
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\u{FEFF}")))
            guard let url = normalizedURL(value, schemes: ["udp", "http", "https"]),
                  seen.count < maximumTrackers, seen.insert(url.absoluteString).inserted else { return nil }
            return url.absoluteString
        }
    }

    /// 每行一个订阅，竖线分隔同一订阅的备用地址；空列表关闭订阅下载。
    public static func subscriptions(_ text: String) throws -> [[URL]] {
        guard text.utf8.count <= maximumResponseSize else { throw PublicTrackerError.invalidSubscriptions }
        var seen: Set<String> = []
        var result: [[URL]] = []
        for line in text.split(whereSeparator: \.isNewline) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let values = line.split(separator: "|", omittingEmptySubsequences: false)
            guard values.count <= 8 else { throw PublicTrackerError.invalidSubscriptions }
            let urls = try values.map { value in
                guard let url = normalizedURL(value.trimmingCharacters(in: .whitespaces), schemes: ["http", "https"]) else {
                    throw PublicTrackerError.invalidSubscriptions
                }
                return url
            }
            if let first = urls.first, seen.insert(first.absoluteString).inserted { result.append(urls) }
            guard result.count <= 32 else { throw PublicTrackerError.invalidSubscriptions }
        }
        return result
    }

    public static func decode(_ data: Data) throws -> [String] {
        guard data.count <= maximumResponseSize else { throw PublicTrackerError.responseTooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw PublicTrackerError.invalidResponse }
        let trackers = parse(text)
        guard !trackers.isEmpty else { throw PublicTrackerError.invalidResponse }
        return trackers
    }

    private static func normalizedURL(_ value: String, schemes: Set<String>) -> URL? {
        guard value.utf8.count <= 2_048, !value.isEmpty,
              !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || $0.value < 32 || $0.value == 127 }),
              var parts = URLComponents(string: value), let scheme = parts.scheme?.lowercased(),
              schemes.contains(scheme), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        parts.scheme = scheme
        parts.host = host.lowercased()
        if (scheme == "http" && parts.port == 80) || (scheme == "https" && parts.port == 443) { parts.port = nil }
        return parts.url
    }
}
