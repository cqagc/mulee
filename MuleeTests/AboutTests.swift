import Foundation
import Testing
@testable import Mulee

@Suite struct AboutTests {
    @Test func displaysMarketingVersionAndBuild() {
        #expect(AboutVersion.display(info: [
            "CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "42"
        ]) == "1.2.3 (42)")
    }

    @Test func packagedVersionMatchesProjectSettings() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let project = try String(contentsOf: root.appending(path: "project.yml"), encoding: .utf8)
        let settings = project.split(separator: "\n")
        for (key, property) in [("MARKETING_VERSION", "CFBundleShortVersionString"), ("CURRENT_PROJECT_VERSION", "CFBundleVersion")] {
            let line = try #require(settings.first { $0.trimmingCharacters(in: .whitespaces).hasPrefix(key + ":") })
            let expected = try #require(line.split(separator: ":", maxSplits: 1).last)
                .trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            #expect(Bundle.main.object(forInfoDictionaryKey: property) as? String == expected)
        }
    }

    @Test func missingVersionIsVisible() {
        #expect(AboutVersion.display(info: [:]) == "— (—)")
    }
}
