import Foundation
import Testing
@testable import Mulee

@Suite struct SettingsReadCoverageTests {
    @Test func everyStoredSettingHasAConsumerOutsideSettings() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let app = root.appending(path: "Mulee")
        let source = try String(contentsOf: app.appending(path: "Features/Settings/SettingsModel.swift"), encoding: .utf8)
        // Top-level settings, including newly added properties without persistence observers.
        let properties = source.matches(of: #/(?m)^    var (\w+)(?::|[ \t]*=)/#).map { String($0.1) }
        #expect(properties.count >= 32)
        let files = try #require(FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil))
        var consumers = ""
        for case let file as URL in files where file.pathExtension == "swift" && !file.path.contains("/Features/Settings/") {
            let text = try String(contentsOf: file, encoding: .utf8)
            // Comments cannot serve as evidence of an actual read.
            consumers += text.components(separatedBy: .newlines).map { line in
                String(line.components(separatedBy: "//").first ?? "")
            }.joined(separator: "\n") + "\n"
        }
        for name in properties {
            let pattern = "\\." + NSRegularExpression.escapedPattern(for: name) + "\\b(?![ \\t]*=(?!=))"
            #expect(consumers.range(of: pattern, options: .regularExpression) != nil, "设置缺少运行时读取方：\(name)")
        }
    }
}
