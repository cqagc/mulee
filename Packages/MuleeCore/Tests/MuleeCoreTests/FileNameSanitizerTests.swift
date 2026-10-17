import Foundation
import Testing
@testable import MuleeCore

struct FileNameSanitizerTests {
    @Test(arguments: ["..", "/:\\\u{0}\n", "   ", "..."])
    func illegalNamesUseSafeFallback(_ name: String) {
        let result = FileNameSanitizer.sanitize(name)

        #expect(result == String(localized: "播放列表", bundle: .module))
        #expect(FileNameSanitizer.sanitize(name, fallback: "../") == String(localized: "播放列表", bundle: .module))
    }

    @Test func removesPathsHiddenPrefixAndControlCharacters() {
        let result = FileNameSanitizer.sanitize(" .. /示例:列表\\名称\n ")

        #expect(result == "示例 列表 名称")
        #expect(!result.hasPrefix("."))
        let root = URL(filePath: "/tmp/example-downloads", directoryHint: .isDirectory)
        let rule = DownloadRule(name: "", subdirectory: result)
        #expect(rule.saveDirectory(under: root)?.deletingLastPathComponent() == root)
    }

    @Test func utf8LimitPreservesCompleteCharacters() {
        let result = FileNameSanitizer.sanitize(String(repeating: "中", count: 100))

        #expect(result == String(repeating: "中", count: 53))
        #expect(result.utf8.count <= 160)
        let emoji = FileNameSanitizer.sanitize(String(repeating: "👩‍💻", count: 30))
        #expect(emoji.utf8.count <= 160)
        #expect(emoji.allSatisfy { $0 == "👩‍💻" })
    }
}
