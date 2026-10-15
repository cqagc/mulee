import Foundation
import Testing
@testable import MuleeCore

struct UnzipRuleMatcherTests {
    private func rule(_ kind: UnzipRule.MatchKind, _ pattern: String, _ id: String? = "password") -> UnzipRule {
        UnzipRule(matchKind: kind, pattern: pattern, keychainItemID: id, maskedLength: 4, hitCount: 0)
    }

    @Test("输入顺序、命中即停，密码本置前也仅兜底")
    func ordering() {
        let book = rule(.passwordBook, "常用密码", nil)
        let prefix = rule(.filenamePrefix, "星*", "first")
        let site = rule(.sourceSite, "example.test", "second")
        let result = UnzipRuleMatcher.match(rules: [book, prefix, site], filename: "星雲.zip", sourceURL: URL(string: "https://example.test/page"))
        #expect(result.matchedRule == prefix)
        #expect(result.sources == [.keychainItem("first")])
        let reversed = UnzipRuleMatcher.match(rules: [site, prefix], filename: "星雲.zip", sourceURL: URL(string: "https://example.test/page"))
        #expect(reversed.matchedRule == site)
    }

    @Test(arguments: ["https://WWW.Example.TEST/page", "https://sub.example.test/x", "https://deep.www.example.test/x"])
    func domains(_ page: String) {
        let source = rule(.sourceSite, "www.EXAMPLE.test")
        #expect(UnzipRuleMatcher.match(rules: [source], filename: "x.zip", sourceURL: URL(string: page)).matchedRule == source)
    }

    @Test(arguments: ["https://evil-example.test", "https://example.test.attacker.test", "file:///example.test"])
    func unrelatedDomains(_ page: String) {
        #expect(UnzipRuleMatcher.match(rules: [rule(.sourceSite, "example.test")], filename: "x.zip", sourceURL: URL(string: page)).sources.isEmpty)
        #expect(UnzipRuleMatcher.match(rules: [rule(.sourceSite, "example.test")], filename: "x.zip", sourceURL: nil).sources.isEmpty)
    }

    @Test("前缀星号支持多个通配，其他正则字符按字面量")
    func wildcard() {
        let prefix = rule(.filenamePrefix, "[星]*雲*.")
        #expect(UnzipRuleMatcher.match(rules: [prefix], filename: "[星]空雲資料.zip", sourceURL: nil).matchedRule == prefix)
        #expect(UnzipRuleMatcher.match(rules: [prefix], filename: "x[星]雲.zip", sourceURL: nil).sources.isEmpty)
    }

    @Test("非法正则给出文案并继续，合法正则可命中")
    func regex() {
        let invalid = rule(.filenameRegex, "[")
        let valid = rule(.filenameRegex, "^星[0-9]+\\.zip$")
        let result = UnzipRuleMatcher.match(rules: [invalid, valid], filename: "星42.zip", sourceURL: nil)
        #expect(result.matchedRule == valid)
        #expect(result.errors.count == 1)
        #expect(result.errors.first?.contains("正则表达式无效") == true)
    }

    @Test("密码本兜底与空规则，没有密码标识的命中也停止")
    func fallback() {
        let book = rule(.passwordBook, "密码本", nil)
        let result = UnzipRuleMatcher.match(rules: [rule(.filenamePrefix, "other"), book], filename: "x.zip", sourceURL: nil)
        #expect(result.sources == [.passwordBook])
        #expect(result.matchedRule == book)
        #expect(UnzipRuleMatcher.match(rules: [], filename: "x.zip", sourceURL: nil).matchedRule == nil)
        #expect(UnzipRuleMatcher.match(rules: [rule(.filenamePrefix, "x", nil), book], filename: "x.zip", sourceURL: nil).sources.isEmpty)
    }

    @Test("内存密码来源保留密码本次序、缺失条目返回 nil")
    func memoryPasswords() async throws {
        let provider = InMemoryPasswordProvider(passwords: ["id": "秘密"], passwordBook: ["one", "two"])
        #expect(try await provider.password(for: "id") == "秘密")
        #expect(try await provider.password(for: "absent") == nil)
        #expect(try await provider.passwordBook() == ["one", "two"])
    }
}
