import Foundation

/// Bilibili 字幕选择。弹幕先下载 XML，任务后处理时转换为 ASS。
public struct YtDlpSubtitles: Sendable {
    public var danmaku: Bool
    public var closedCaptions: Bool

    public init(danmaku: Bool = false, closedCaptions: Bool = false) {
        self.danmaku = danmaku
        self.closedCaptions = closedCaptions
    }

    public var arguments: [String] {
        guard danmaku || closedCaptions else { return [] }
        let languages = closedCaptions ? (danmaku ? "all" : "all,-danmaku") : "danmaku"
        return ["--write-subs", "--sub-langs", languages]
    }
}

public enum YtDlpSubtitleLanguage {
    public static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 128 && id.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || "_-".utf8.contains($0)
        }
    }

    public static func preferredIDs(in available: [String], preferences: [String]) -> [String] {
        available.filter { language in
            preferences.contains { preference in
                language.caseInsensitiveCompare(preference) == .orderedSame
                    || (preference == "zh-Hans" && ["zh-CN", "zh-SG"].contains(language))
                    || (preference == "zh-Hant" && ["zh-TW", "zh-HK"].contains(language))
            }
        }
    }
}
