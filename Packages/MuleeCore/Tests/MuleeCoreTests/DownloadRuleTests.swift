import Foundation
import Testing
@testable import MuleeCore

struct DownloadRuleTests {
    @Test func domainBoundariesAndWildcards() {
        #expect(RuleMatcher.domain("sub.example.test", matches: "example.test"))
        #expect(RuleMatcher.domain("WWW.Example.test.", matches: "https://example.test/"))
        #expect(RuleMatcher.domain("cdn.example.test", matches: "*.example.test"))
        #expect(RuleMatcher.domain("cdn.example.test", matches: "*.example.test", allowsWildcards: false) == false)
        #expect(!RuleMatcher.domain("example.test.attacker.test", matches: "*.example.test"))
        #expect(!RuleMatcher.domain("evil-example.test", matches: "example.test"))
        #expect(!RuleMatcher.domain(nil, matches: "*"))
        #expect(RuleMatcher.wildcard("a[1]-file.zip", matches: "a[1]*", prefix: true))
        let legacy = UnzipRule(matchKind: .sourceSite, pattern: "*.example.test", keychainItemID: nil, maskedLength: 0, hitCount: 0)
        #expect(UnzipRuleMatcher.match(rules: [legacy], filename: "file.zip", sourceURL: URL(string: "https://cdn.example.test")).matchedRule == nil)
    }

    @Test func firstMatchUsesRefererThenDownloadHostAndAllConditions() {
        let first = DownloadRule(name: "first", sourceSite: "*.example.test", extensions: [".ZIP"], taskKind: .http)
        let second = DownloadRule(name: "fallback")
        let url = URL(string: "https://files.other.test/file.zip")
        let context = DownloadRequestContext(referer: URL(string: "https://page.example.test/article"))
        #expect(DownloadRule.firstMatch(in: [first, second], context: context, downloadURL: url, filename: "file.zip", kind: .http) == first)
        #expect(DownloadRule.firstMatch(in: [first, second], context: .init(), downloadURL: url, filename: "file.zip", kind: .http) == second)
        #expect(DownloadRule.firstMatch(in: [first, second], context: context, downloadURL: url, filename: "file.mp4", kind: .http) == second)
        #expect(DownloadRule.firstMatch(in: [first, second], context: context, downloadURL: url, filename: "file.zip", kind: .video) == second)
        #expect(DownloadRule.firstMatch(in: [first], context: .init(), downloadURL: context.referer, filename: "file.zip", kind: .http) == first)
    }

    @Test func categoriesAndSafeDirectories() {
        #expect(DownloadCategory.classify(extension: "MP4") == .video)
        #expect(DownloadCategory.classify(extension: "flac") == .audio)
        #expect(DownloadCategory.classify(extension: ".zip") == .archive)
        #expect(DownloadCategory.classify(extension: "pdf") == .document)
        #expect(DownloadCategory.classify(extension: "pkg") == .program)
        #expect(DownloadCategory.classify(extension: "dmg") == .image)
        #expect(DownloadCategory.classify(extension: nil) == nil)
        let root = URL(filePath: "/tmp/download-rule-tests")
        #expect(DownloadRule(name: "safe", subdirectory: "site/docs").saveDirectory(under: root)?.path == root.path + "/site/docs")
        for path in ["../escape", "/absolute", "site/../../escape", "folder\\escape"] {
            #expect(DownloadRule(name: "unsafe", subdirectory: path).saveDirectory(under: root) == nil)
        }
    }

    @Test func optionalTaskFieldsDecodeOldHistory() throws {
        var task = DownloadTask(name: "file.zip", fileExtension: "zip", kind: .http, status: .completed,
                                totalBytes: 1, receivedBytes: 1, detail: .http(connections: 0),
                                postDownload: PostDownloadInfo(autoExtract: false), sourceLink: "https://example.test/file.zip")
        let oldData = try JSONEncoder().encode(task)
        let oldTask = try JSONDecoder().decode(DownloadTask.self, from: oldData)
        #expect(oldTask.tags == nil && oldTask.deletedAt == nil && oldTask.fileBookmark == nil)
        task.tags = ["work"]
        task.deletedAt = Date(timeIntervalSince1970: 100)
        task.fileBookmark = Data([1, 2])
        #expect(try JSONDecoder().decode(DownloadTask.self, from: JSONEncoder().encode(task)) == task)
    }
}
