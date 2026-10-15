import Foundation
import MuleeCore

/// 只持久化规则及钥匙串标识，不接收密码。
@MainActor
final class UnzipRuleStore {
    private let defaults: UserDefaults
    private let key = "unzip.rules"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() throws -> [UnzipRule] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return try JSONDecoder().decode([UnzipRule].self, from: data)
    }

    func save(_ rules: [UnzipRule]) throws {
        defaults.set(try JSONEncoder().encode(rules), forKey: key)
    }
}
