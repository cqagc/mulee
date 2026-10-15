import Foundation
import Testing
@testable import Mulee

@Suite struct LocalizationTests {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private var catalogPaths: [String] {
        [
            "Mulee/Resources/Localizable.xcstrings",
            "Mulee/Resources/InfoPlist.xcstrings",
            "Packages/MuleeCore/Sources/MuleeCore/Resources/Localizable.xcstrings"
        ]
    }

    @Test func catalogsHaveCompleteTranslationsAndMatchingArguments() throws {
        for path in catalogPaths {
            let catalog = try catalog(at: path)
            #expect(catalog["sourceLanguage"] as? String == "zh-Hans")
            let strings = try #require(catalog["strings"] as? [String: [String: Any]])
            #expect(!strings.isEmpty)
            for (key, entry) in strings {
                let localizations = try #require(entry["localizations"] as? [String: [String: Any]])
                let source = try #require(localizations["zh-Hans"])
                let sourceValue = try #require((source["stringUnit"] as? [String: String])?["value"])
                let expected = try placeholders(in: sourceValue)
                for language in ["en", "zh-Hant"] {
                    let localization = try #require(localizations[language], "\(path): \(key) missing \(language)")
                    let values = try expandedValues(localization)
                    #expect(!values.isEmpty)
                    for value in values {
                        #expect(try placeholders(in: value) == expected, "\(path): \(key) [\(language)] \(value)")
                    }
                }
            }
        }
    }

    @Test func translationsFollowGlossaryAndLanguage() throws {
        let glossary = try String(contentsOf: root.appending(path: "docs/GLOSSARY.md"), encoding: .utf8)
        let forbidden = glossary.split(separator: "\n").compactMap { row -> String? in
            let cells = row.split(separator: "|", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard cells.count == 6, cells[1] != cells[3], cells[1] != "简体中文",
                  cells[1].range(of: #"[\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF]"#, options: .regularExpression) != nil else { return nil }
            return cells[1]
        }
        #expect(forbidden.contains("文件"))
        #expect(forbidden.contains("视频"))
        #expect(forbidden.contains("设置"))
        #expect(forbidden.contains("链接"))
        for path in catalogPaths {
            let strings = try #require(try catalog(at: path)["strings"] as? [String: [String: Any]])
            for (key, entry) in strings {
                let localizations = try #require(entry["localizations"] as? [String: [String: Any]])
                for value in try expandedValues(try #require(localizations["en"])) {
                    #expect(value.range(of: #"[\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF]"#, options: .regularExpression) == nil, "\(path): \(key): \(value)")
                }
                for value in try expandedValues(try #require(localizations["zh-Hant"])) {
                    for term in forbidden {
                        #expect(!value.contains(term), "\(path): \(key): simplified term \(term)")
                    }
                }
            }
        }
    }

    @Test func englishPluralsRenderFromCompiledCatalog() throws {
        let path = try #require(Bundle.main.path(forResource: "en", ofType: "lproj"))
        let english = try #require(Bundle(path: path))
        let locale = Locale(identifier: "en")
        for (days, expected) in [(0, "Waiting for 0 days"), (1, "Waiting for 1 day"), (2, "Waiting for 2 days")] {
            #expect(String(localized: "已挂 \(days) 天", bundle: english, locale: locale) == expected)
        }
        let size = "612 MB"
        let sources = 1
        let queue = ", queue position 14"
        #expect(String(localized: "\(size) · \(sources) 个来源\(queue)", bundle: english, locale: locale)
                == "612 MB · 1 source, queue position 14")
        let files = 1
        let selected = 3
        let peers = 2
        #expect(String(localized: "\(files) 个文件，已选 \(selected) 个 · \(peers) 个节点", bundle: english, locale: locale)
                == "1 file, 3 selected · 2 peers")
    }

    @Test func compiledAppAndCoreCatalogsUseTaiwanTerminology() throws {
        let coreURL = try #require(Bundle.main.url(forResource: "MuleeCore_MuleeCore", withExtension: "bundle"))
        let core = try #require(Bundle(url: coreURL))
        let traditionalPath = try #require(Bundle.main.path(forResource: "zh-Hant", ofType: "lproj"))
        let traditional = try #require(Bundle(path: traditionalPath))
        #expect(String(localized: "视频", bundle: traditional) == "影片")
        #expect(String(localized: "文件夹", bundle: traditional) == "資料夾")
        #expect(String(localized: "磁盘缓存", bundle: traditional) == "磁碟快取")
        for (language, expected) in [("en", "Archive is damaged"), ("zh-Hant", "壓縮檔損壞")] {
            let path = try #require(core.path(forResource: language, ofType: "lproj"))
            let localized = try #require(Bundle(path: path))
            #expect(String(localized: "压缩包损坏", bundle: localized) == expected)
        }
    }

    private func catalog(at path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: root.appending(path: path))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func expandedValues(_ node: [String: Any]) throws -> [String] {
        if let unit = node["stringUnit"] as? [String: String] {
            #expect(unit["state"] == "translated")
            var values = [try #require(unit["value"])]
            if let substitutions = node["substitutions"] as? [String: [String: Any]] {
                for (name, substitution) in substitutions {
                    let variants = try expandedValues(substitution)
                    values = values.flatMap { value in
                        variants.map { value.replacingOccurrences(of: "%#@\(name)@", with: $0) }
                    }
                }
            }
            return values
        }
        let variations = try #require(node["variations"] as? [String: [String: [String: Any]]])
        if let plural = variations["plural"] {
            #expect(plural["one"] != nil)
            #expect(plural["other"] != nil)
        }
        return try variations.values.flatMap { variants in
            try variants.values.flatMap { try expandedValues($0) }
        }
    }

    private func placeholders(in value: String) throws -> [String] {
        let expression = try NSRegularExpression(pattern: #"%(?:\d+\$)?(?:@|lld|llu|ld|lu|d|u|f|g)"#)
        let range = NSRange(value.startIndex..., in: value)
        return expression.matches(in: value.replacingOccurrences(of: "%%", with: "  "), range: range).map { match in
            let token = (value as NSString).substring(with: match.range)
            return token.replacingOccurrences(of: #"\d+\$"#, with: "", options: .regularExpression)
        }.sorted()
    }
}
