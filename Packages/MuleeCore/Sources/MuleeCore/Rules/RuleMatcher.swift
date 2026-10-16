import Foundation

/// 下载规则与解压规则共用；域名按标签边界匹配，避免相似域名误命中。
public enum RuleMatcher {
    public static func domain(_ host: String?, matches pattern: String, allowsWildcards: Bool = true) -> Bool {
        let host = normalizedDomain(host ?? "")
        let domain = normalizedDomain(pattern)
        guard !host.isEmpty, !domain.isEmpty else { return false }
        if allowsWildcards, domain.contains("*") {
            return wildcard(host, matches: domain)
        }
        return host == domain || host.hasSuffix("." + domain)
    }

    public static func wildcard(_ value: String, matches pattern: String, prefix: Bool = false) -> Bool {
        let expression = pattern.components(separatedBy: "*")
            .map(NSRegularExpression.escapedPattern(for:)).joined(separator: ".*")
        return value.range(of: "^" + expression + (prefix ? "" : "$"), options: .regularExpression) != nil
    }

    private static func normalizedDomain(_ value: String) -> String {
        var domain = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let host = URL(string: domain)?.host { domain = host }
        while domain.hasSuffix(".") { domain.removeLast() }
        if domain.hasPrefix("www.") { domain.removeFirst(4) }
        return domain
    }
}
