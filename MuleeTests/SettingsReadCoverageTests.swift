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
        #expect(properties.count >= 36)
        for name in ["downloadRules", "sortIntoFolders", "publicTrackersEnabled", "trackerSubscriptions", "customTrackers", "blockLeechingClients",
                     "markIncomplete", "duplicateAction", "videoFormatChoiceBySite", "skipJunkFiles", "junkFilePatterns", "seedTimeLimitMinutes", "seedInactiveLimitMinutes",
                     "privateMinSeedMinutes", "ipBlocklistPath", "watchFolders", "watchAutoStart",
                     "transferScheduleEnabled", "transferScheduleStartTime", "transferScheduleEndTime", "transferScheduleWeekdays"] {
            #expect(properties.contains(name))
        }
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

    @Test func diskCacheHasAConsumerInEveryEngine() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let bt = try String(contentsOf: root.appending(path: "Mulee/Engine/BitTorrentEngineConfiguration.swift"), encoding: .utf8)
        #expect(bt.contains("configuration.diskCacheBytes ="))
        #expect(bt.contains("settings.diskCacheMB"))
        let core = root.appending(path: "Packages/MuleeCore/Sources/MuleeCore/Engine")
        for path in ["Aria2/Aria2Configuration.swift", "Ed2k/Ed2kConfiguration.swift", "YtDlp/YtDlpEngine.swift"] {
            let source = try String(contentsOf: core.appending(path: path), encoding: .utf8)
            let code = source.components(separatedBy: .newlines).map {
                String($0.components(separatedBy: "//").first ?? "")
            }.joined(separator: "\n")
            #expect(code.contains("options.diskCacheMegabytes"), "磁盘缓存缺少引擎读取方：\(path)")
        }
    }
}
