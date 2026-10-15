import Foundation

/// yt-dlp 的 Bilibili flat entries 没有标题；公开接口只补标题及当前视频所属合集。
/// 独立临时会话不读取系统 Cookie，不持久化响应或登录状态。
enum YtDlpBilibiliMetadata {
    static func enrich(_ entries: [YtDlpPlaylistEntry], source: URL) async -> [YtDlpPlaylistEntry] {
        let identifier = source.lastPathComponent
        guard identifier.hasPrefix("BV") || identifier.hasPrefix("av") else { return entries }
        var components = URLComponents(string: "https://api.bilibili.com/x/web-interface/view")
        let key = identifier.hasPrefix("BV") ? "bvid" : "aid"
        let value = identifier.hasPrefix("BV") ? identifier : String(identifier.dropFirst(2))
        components?.queryItems = [URLQueryItem(name: key, value: value)]
        guard let url = components?.url else { return entries }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 8
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            var request = URLRequest(url: url)
            request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
            request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Origin")
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36",
                forHTTPHeaderField: "User-Agent"
            )
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 4_194_304,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let video = object["data"] as? [String: Any] else { return entries }
            return enrich(entries, video: video, source: source)
        } catch {
            return entries
        }
    }

    static func enrich(_ entries: [YtDlpPlaylistEntry], video: [String: Any], source: URL) -> [YtDlpPlaylistEntry] {
        if entries.count > 1, let pages = video["pages"] as? [[String: Any]] {
            return entries.map { entry in
                let part = YtDlpPlaylistEntry.selectedPart(in: entry.url)
                let title = pages.first { $0["page"] as? Int == part }?["part"] as? String
                return YtDlpPlaylistEntry(index: entry.index, title: String((title ?? entry.title).prefix(512)), url: entry.url)
            }
        }
        guard entries.isEmpty, let season = video["ugc_season"] as? [String: Any],
              let sections = season["sections"] as? [[String: Any]] else { return entries }
        let episodes = sections.flatMap { $0["episodes"] as? [[String: Any]] ?? [] }
        guard episodes.count > 1, episodes.count <= 1_000 else { return entries }
        var seen = Set<URL>()
        return episodes.enumerated().compactMap { offset, episode in
            guard let bvid = episode["bvid"] as? String,
                  bvid.hasPrefix("BV"), bvid.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }),
                  let url = URL(string: "https://www.bilibili.com/video/" + bvid + "?p=1"),
                  seen.insert(url).inserted else { return nil }
            return YtDlpPlaylistEntry(index: offset + 1, title: String((episode["title"] as? String ?? "").prefix(512)), url: url)
        }
    }
}
