import Foundation

/// AppleLanguages 属于主 App；浏览器扩展跟随浏览器，Quick Look 扩展跟随系统。
enum AppLanguage: String, CaseIterable, Identifiable {
    case system = ""
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"
    case japanese = "ja"

    var id: String { rawValue }

    var nativeName: String {
        switch self {
        case .system: String(localized: "跟随系统")
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        case .english: "English"
        case .japanese: "日本語"
        }
    }

    static func read(defaults: UserDefaults, domain: String) -> Self {
        // 不能读合并后的全局域，否则「跟随系统」也会显示成某个具体语言。
        let value = defaults.persistentDomain(forName: domain)?["AppleLanguages"] as? [String]
        return language(for: value?.first)
    }

    static func language(for code: String?) -> Self {
        guard let originalCode = code else { return .system }
        let code = originalCode.replacingOccurrences(of: "_", with: "-")
        for language in allCases where language != .system {
            if code == language.rawValue || code.hasPrefix(language.rawValue + "-") {
                return language
            }
        }
        switch code {
        case "zh-CN", "zh-SG": return .simplifiedChinese
        case "zh-TW", "zh-HK", "zh-MO": return .traditionalChinese
        default: return .system
        }
    }

    func write(defaults: UserDefaults) {
        if self == .system {
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([rawValue], forKey: "AppleLanguages")
        }
    }
}
