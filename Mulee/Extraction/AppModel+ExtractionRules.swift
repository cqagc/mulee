import Foundation
import MuleeCore

extension AppModel {
    func loadUnzipRules(from store: UnzipRuleStore) {
        do {
            let rules = try store.load()
            unzipRuleStore = store
            unzipRules = rules
            unzipRuleIssue = nil
        } catch {
            unzipRuleIssue = String(localized: "暂时无法读取解压规则：\(error.localizedDescription)")
        }
    }

    func persistUnzipRules() {
        do {
            try unzipRuleStore?.save(unzipRules)
        } catch {
            unzipRuleIssue = String(localized: "暂时无法保存解压规则：\(error.localizedDescription)")
        }
    }

    func addUnzipRule(kind: UnzipRule.MatchKind, pattern: String, password: String) async throws {
        let itemID = "rule-" + UUID().uuidString
        try await extractionPasswords.setPassword(password, for: itemID)
        unzipRules.append(UnzipRule(
            matchKind: kind, pattern: pattern, keychainItemID: itemID,
            maskedLength: password.count, hitCount: 0
        ))
    }

    func removeUnzipRule(_ id: UnzipRule.ID) async throws {
        guard let rule = unzipRules.first(where: { $0.id == id }) else { return }
        if let itemID = rule.keychainItemID {
            try await extractionPasswords.setPassword(nil, for: itemID)
        }
        unzipRules.removeAll { $0.id == id }
    }

    func saveExtractionPasswordBook(_ passwords: [String]) async throws {
        try await extractionPasswords.setPasswordBook(passwords)
        if !passwords.isEmpty, !unzipRules.contains(where: { $0.matchKind == .passwordBook }) {
            unzipRules.append(UnzipRule(
                matchKind: .passwordBook, pattern: String(localized: "以上都没命中时，依次尝试密码本"),
                keychainItemID: nil, maskedLength: 0, hitCount: 0
            ))
        }
    }
}
