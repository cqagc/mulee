import Foundation

public enum UnzipRuleMatcher {
    /// 普通规则遵循输入顺序；密码本始终是所有普通规则都未命中时的兜底。
    public static func match(rules: [UnzipRule], filename: String, sourceURL: URL?) -> UnzipRuleMatch {
        var errors: [String] = []
        for rule in rules where rule.matchKind != .passwordBook {
            let matches: Bool
            switch rule.matchKind {
            case .sourceSite:
                matches = RuleMatcher.domain(sourceURL?.host, matches: rule.pattern, allowsWildcards: false)
            case .filenamePrefix:
                matches = RuleMatcher.wildcard(filename, matches: rule.pattern, prefix: true)
            case .filenameRegex:
                do {
                    let expression = try NSRegularExpression(pattern: rule.pattern)
                    matches = expression.firstMatch(in: filename, range: NSRange(filename.startIndex..., in: filename)) != nil
                } catch {
                    errors.append(String(localized: "密码规则「\(rule.pattern)」的正则表达式无效", bundle: .module))
                    continue
                }
            case .passwordBook:
                matches = false
            }
            if matches {
                let sources = rule.keychainItemID.map { [UnzipPasswordSource.keychainItem($0)] } ?? []
                return UnzipRuleMatch(sources: sources, matchedRule: rule, errors: errors)
            }
        }
        let book = rules.first { $0.matchKind == .passwordBook }
        return UnzipRuleMatch(sources: book == nil ? [] : [.passwordBook], matchedRule: book, errors: errors)
    }

}
