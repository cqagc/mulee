import Foundation

/// 全局设置与逐任务选择在这里合成为参数，不读取偏好或文件系统。
public struct YtDlpOutputOptions: Equatable, Sendable {
    public enum SubtitleMode: String, Codable, CaseIterable, Sendable {
        case off
        case embed
        case file
    }

    public enum AudioFormat: String, Codable, CaseIterable, Sendable {
        case m4a
        case mp3
    }

    public enum CodecPreference: String, Codable, CaseIterable, Sendable {
        case auto
        case h264
        case hevc
        case av1
        case vp9

        var sort: String? {
            switch self {
            case .auto: nil
            case .h264: "vcodec:h264"
            case .hevc: "vcodec:h265"
            case .av1: "vcodec:av1"
            case .vp9: "vcodec:vp9"
            }
        }
    }

    public enum FilenamePreset: String, Codable, CaseIterable, Sendable {
        case title
        case uploaderTitle
        case dateTitle

        public var template: String {
            switch self {
            case .title: "%(title).160B.%(ext)s"
            case .uploaderTitle: "%(uploader,channel|Unknown).40B - %(title).117B.%(ext)s"
            case .dateTitle: "%(upload_date>%Y-%m-%d|Unknown)s - %(title).147B.%(ext)s"
            }
        }
    }

    public var subtitleMode: SubtitleMode = .off
    public var subtitleLanguages: [String] = preferredSubtitleLanguages()
    public var autoCaptions = false
    public var audioFormat: AudioFormat = .m4a
    public var embedMetadata = true
    public var sponsorBlockMark = false
    public var codecPreference: CodecPreference = .auto
    public var prefer60fps = false
    public var filenamePreset: FilenamePreset = .title

    public init() {}

    public static func preferredSubtitleLanguages(_ languages: [String] = Locale.preferredLanguages) -> [String] {
        var result: [String] = []
        for language in languages {
            let parts = language.replacingOccurrences(of: "_", with: "-").split(separator: "-")
            guard let base = parts.first else { continue }
            let mapped: String
            if base == "zh" {
                mapped = parts.contains("Hant") || parts.contains("TW") || parts.contains("HK") ? "zh-Hant" : "zh-Hans"
            } else {
                mapped = String(base)
            }
            if !result.contains(mapped) { result.append(mapped) }
        }
        return result
    }

    public func arguments(
        quality: YtDlpQuality, site: VideoSite, task: YtDlpTaskOptions = .init(),
        formatID: String? = nil, formatVideoOnly: Bool = false,
        bilibiliSubtitles: YtDlpSubtitles = .init(), includeThumbnail: Bool = true
    ) -> [String] {
        let audioOnly = task.audioOnly == true
        var result: [String]
        if audioOnly {
            result = ["-f", "bestaudio", "-x", "--audio-format", audioFormat.rawValue]
        } else {
            result = quality.arguments(codecPreference: codecPreference)
            if let formatID, YtDlpFormat.isValidID(formatID) {
                result += ["--format", formatVideoOnly ? formatID + "+ba/" + formatID : formatID]
            }
            let sort = [codecPreference.sort, prefer60fps ? "fps:60" : nil].compactMap { $0 }
            if !sort.isEmpty { result += ["-S", sort.joined(separator: ",")] }
            if site == .bilibili {
                result += bilibiliSubtitles.arguments
            } else if subtitleMode != .off {
                let languages = (task.subtitleLanguages ?? subtitleLanguages).filter(YtDlpSubtitleLanguage.isValidID)
                if !languages.isEmpty {
                    result += ["--write-subs", "--sub-langs", languages.map { "^" + NSRegularExpression.escapedPattern(for: $0) + "$" }.joined(separator: ",")]
                    if autoCaptions { result.append("--write-auto-subs") }
                    result += subtitleMode == .file ? ["--convert-subs", "srt"] : ["--embed-subs"]
                }
            }
        }
        if embedMetadata {
            result += ["--embed-metadata", "--embed-chapters", "--no-embed-info-json"]
            if includeThumbnail { result.append("--embed-thumbnail") }
        }
        if sponsorBlockMark, site == .youtube {
            result += ["--sponsorblock-mark", "sponsor,selfpromo,intro,outro", "--embed-chapters"]
        }
        if let section = task.section { result += ["--download-sections", section.argument] }
        return result
    }
}

/// 可选字段让旧任务无需迁移；nil 语言列表跟随全局，空列表表示本次不下字幕。
public struct YtDlpTaskOptions: Codable, Hashable, Sendable {
    public var subtitleLanguages: [String]?
    public var audioOnly: Bool?
    public var section: YtDlpTimeSection?

    public init(subtitleLanguages: [String]? = nil, audioOnly: Bool? = nil, section: YtDlpTimeSection? = nil) {
        self.subtitleLanguages = subtitleLanguages
        self.audioOnly = audioOnly
        self.section = section
    }

    public func validate() throws {
        if let subtitleLanguages, !subtitleLanguages.allSatisfy(YtDlpSubtitleLanguage.isValidID) {
            throw EngineError.invalidResponse(String(localized: "字幕语言无效，请重新选择", bundle: .module))
        }
        if let section, !section.isValid { throw YtDlpTimeSection.ValidationError.invalid }
    }
}

public struct YtDlpTimeSection: Codable, Hashable, Sendable {
    public enum ValidationError: String, Error, LocalizedError {
        case invalid = "时间段无效，请填写时:分:秒、分:秒或秒数，结束时间须大于开始时间"
        public var errorDescription: String? {
            switch self {
            case .invalid: String(localized: "时间段无效，请填写时:分:秒、分:秒或秒数，结束时间须大于开始时间", bundle: .module)
            }
        }
    }

    public let start: Double
    public let end: Double

    public init(start: String, end: String) throws {
        guard let start = Self.seconds(start), let end = Self.seconds(end), end > start else { throw ValidationError.invalid }
        self.start = start
        self.end = end
    }

    public var isValid: Bool { start.isFinite && end.isFinite && start >= 0 && end > start }
    public var argument: String { "*\(Self.timestamp(start))-\(Self.timestamp(end))" }

    public static func seconds(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var result = 0.0
        for (index, part) in parts.enumerated() {
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }),
                  let value = Double(part), value.isFinite, value >= 0,
                  (index == parts.count - 1 || !part.contains(".")),
                  (index == 0 || value < 60) else { return nil }
            result = result * 60 + value
        }
        return result.isFinite ? result : nil
    }

    private static func timestamp(_ value: Double) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US_POSIX"))
            .grouping(.never).precision(.significantDigits(1...17)))
    }
}
