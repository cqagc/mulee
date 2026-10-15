import Foundation

public struct YtDlpPlaylistEntry: Sendable, Identifiable, Equatable {
    public let index: Int
    public let title: String
    public let url: URL
    public var id: URL { url }

    public init(index: Int, title: String, url: URL) {
        self.index = index
        self.title = title
        self.url = url
    }

    public var displayTitle: String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return "P\(index)" }
        if url.path.hasPrefix("/bangumi/play/") { return title }
        let prefix = "P\(index)"
        if title == prefix || title.hasPrefix(prefix + " ") { return title }
        return prefix + " · " + title
    }

    public var taskTitle: String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "P\(index)" : title
    }

    public var link: ParsedLink { .video(url: url, site: .bilibili, original: url.absoluteString) }

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
