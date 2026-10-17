import Foundation

/// 一次 -J 同时提供格式、字幕与身份，避免新建面板重复探测视频。
public struct YtDlpVideoMetadata: Sendable {
    public let formats: [YtDlpFormat]
    public let subtitleLanguages: [String]
    public let automaticCaptionLanguages: [String]
    public let videoIdentity: String?
    public let title: String?
    public let duration: Double?

    public init(
        formats: [YtDlpFormat], subtitleLanguages: [String] = [],
        automaticCaptionLanguages: [String] = [], videoIdentity: String? = nil,
        title: String? = nil, duration: Double? = nil
    ) {
        self.formats = formats
        self.subtitleLanguages = subtitleLanguages
        self.automaticCaptionLanguages = automaticCaptionLanguages
        self.videoIdentity = videoIdentity
        self.title = title
        self.duration = duration
    }

    public static func parse(_ data: Data) throws -> YtDlpVideoMetadata {
        let formats = try YtDlpFormats.parse(data)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        // 人工字幕和自动字幕可使用同一语言，分别保留供用户切换。
        func languages(_ key: String) -> [String] {
            let tracks = object[key] as? [String: [[String: Any]]] ?? [:]
            return tracks.keys.filter { id in
                !id.isEmpty && id.utf8.count <= 128 && !["danmaku", "live_chat"].contains(id)
                    && id.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || "_-".utf8.contains($0) }
                    && tracks[id]?.isEmpty == false
            }.sorted()
        }
        let duration = (object["duration"] as? NSNumber)?.doubleValue
        return YtDlpVideoMetadata(
            formats: formats, subtitleLanguages: languages("subtitles"),
            automaticCaptionLanguages: languages("automatic_captions"), videoIdentity: YtDlpFormats.videoIdentity(in: data),
            title: (object["title"] as? String).map { String($0.prefix(512)) },
            duration: duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        )
    }
}
