import Foundation

public struct YtDlpPlaylistEntry: Sendable, Identifiable, Equatable {
    public let index: Int
    public let title: String
    public let url: URL
    public let site: VideoSite
    public let duration: Double?
    public let playlistTitle: String?
    public let videoIdentity: String?
    public let playlistCount: Int?
    public var id: URL { url }

    public init(
        index: Int, title: String, url: URL, site: VideoSite = .bilibili,
        duration: Double? = nil, playlistTitle: String? = nil, videoIdentity: String? = nil, playlistCount: Int? = nil
    ) {
        self.index = index
        self.title = title
        self.url = url
        self.site = site
        self.duration = duration
        self.playlistTitle = playlistTitle
        self.videoIdentity = videoIdentity
        self.playlistCount = playlistCount
    }

    public var displayTitle: String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if site == .youtube { return title.isEmpty ? "#\(index)" : "#\(index) \(title)" }
        guard !title.isEmpty else { return "P\(index)" }
        if url.path.hasPrefix("/bangumi/play/") { return title }
        let prefix = "P\(index)"
        if title == prefix || title.hasPrefix(prefix + " ") { return title }
        return prefix + " · " + title
    }

    public var filenamePrefix: String {
        guard site == .youtube else { return "P\(index) " }
        let width = max(index, playlistCount ?? 0) > 99 ? 3 : 2
        let number = String(index)
        return String(repeating: "0", count: max(0, width - number.count)) + number + " - "
    }

    public var taskTitle: String {
        if site == .youtube { return filenamePrefix + title.trimmingCharacters(in: .whitespacesAndNewlines) }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "P\(index)" : title
    }

    public var link: ParsedLink { .video(url: url, site: site, original: url.absoluteString) }

    public var durationDescription: String? {
        guard let duration, duration.isFinite, duration > 0, duration < 31_536_000 else { return nil }
        return Duration.seconds(duration).formatted(.time(pattern: duration >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }

    public static func selectedPart(in url: URL) -> Int {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let value = components.queryItems?.first(where: { $0.name == "p" })?.value,
              let index = Int(value), index > 0, index <= 10_000 else { return 1 }
        return index
    }

    public static func arguments(for url: URL, site: VideoSite) -> [String] {
        // 显式 p 由 Bilibili extractor 选择，禁止再展开整个视频或合集。
        site == .bilibili ? ["--no-playlist", "--playlist-items", String(selectedPart(in: url))] : ["--no-playlist"]
    }
}
