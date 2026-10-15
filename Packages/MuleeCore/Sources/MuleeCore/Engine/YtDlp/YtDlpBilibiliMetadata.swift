import Foundation

/// 公开接口优先获取分 P、合集及番剧列表；失败时交回 yt-dlp。
/// 独立临时会话只使用显式传入的 Cookie，不读取系统 Cookie 或持久化登录状态。
enum YtDlpBilibiliMetadata {
    typealias Loader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static func fetch(
        source: URL, cookies: [VideoCookie] = [], load: Loader? = nil
    ) async -> [YtDlpPlaylistEntry]? {
        guard VideoCookie.allows(domain: source.host ?? "", site: .bilibili),
              ["http", "https"].contains(source.scheme ?? ""), source.user == nil, source.password == nil else { return nil }
        let path = source.path.split(separator: "/").map(String.init)
        guard let identifier = path.last else { return nil }
        let isSeason = path.count == 3 && path[0] == "bangumi" && path[1] == "play"
        var components: URLComponents?
        if isSeason {
            let key: String
            if identifier.hasPrefix("ss") { key = "season_id" }
            else if identifier.hasPrefix("ep") { key = "ep_id" }
            else { return nil }
            let value = String(identifier.dropFirst(2))
            guard isNumber(value) else { return nil }
            components = URLComponents(string: "https://api.bilibili.com/pgc/view/web/season")
            components?.queryItems = [URLQueryItem(name: key, value: value)]
        } else {
            guard path.count == 2, path[0] == "video",
                  identifier.hasPrefix("BV") || identifier.hasPrefix("av"),
                  identifier.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else { return nil }
            components = URLComponents(string: "https://api.bilibili.com/x/web-interface/view")
            let key = identifier.hasPrefix("BV") ? "bvid" : "aid"
            let value = identifier.hasPrefix("BV") ? identifier : String(identifier.dropFirst(2))
            components?.queryItems = [URLQueryItem(name: key, value: value)]
        }
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Origin")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        let cookieHeader = cookies.filter { cookie in
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            let matchesHost = url.host == domain || (!cookie.hostOnly && url.host?.hasSuffix("." + domain) == true)
            let matchesPath = url.path == cookie.path || url.path.hasPrefix(cookie.path.hasSuffix("/") ? cookie.path : cookie.path + "/")
            return cookie.isValid(for: .bilibili) && matchesHost && matchesPath
                && !cookie.value.contains(";") && (cookie.expirationDate.map { $0 > Date().timeIntervalSince1970 } ?? true)
        }.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        if !cookieHeader.isEmpty { request.setValue(cookieHeader, forHTTPHeaderField: "Cookie") }
        do {
            let data: Data
            let response: URLResponse
            if let load {
                (data, response) = try await load(request)
            } else {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.httpShouldSetCookies = false
                configuration.httpCookieStorage = nil
                configuration.timeoutIntervalForRequest = 10
                configuration.timeoutIntervalForResource = 10
                let session = URLSession(configuration: configuration)
                defer { session.invalidateAndCancel() }
                (data, response) = try await session.data(for: request)
            }
            guard !Task.isCancelled, (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 4_194_304,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["code"] as? Int == 0 else { return nil }
            if isSeason {
                guard let season = object["result"] as? [String: Any] else { return nil }
                return episodes(in: season)
            }
            guard let video = object["data"] as? [String: Any],
                  let pages = video["pages"] as? [[String: Any]], !pages.isEmpty, pages.count <= 1_000 else { return nil }
            if pages.count == 1 { return enrich([], video: video, source: source) }
            var entries: [YtDlpPlaylistEntry] = []
            var seen = Set<Int>()
            for page in pages {
                guard let index = page["page"] as? Int, index > 0, index <= 10_000,
                      seen.insert(index).inserted, let title = page["part"] as? String,
                      let url = URL(string: "https://www.bilibili.com/video/" + identifier + "?p=\(index)") else { return nil }
                entries.append(YtDlpPlaylistEntry(index: index, title: String(title.prefix(512)), url: url))
            }
            return entries
        } catch {
            return nil
        }
    }

    private static func episodes(in season: [String: Any]) -> [YtDlpPlaylistEntry]? {
        guard let episodes = season["episodes"] as? [[String: Any]],
              !episodes.isEmpty, episodes.count <= 1_000 else { return nil }
        var entries: [YtDlpPlaylistEntry] = []
        var seen = Set<Int>()
        for (offset, episode) in episodes.enumerated() {
            guard let id = (episode["ep_id"] as? Int) ?? (episode["id"] as? Int), id > 0,
                  seen.insert(id).inserted, let number = episode["title"] as? String,
                  let url = URL(string: "https://www.bilibili.com/bangumi/play/ep\(id)") else { return nil }
            let numberTitle = number.trimmingCharacters(in: .whitespacesAndNewlines)
            let longTitle = (episode["long_title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let label = isNumber(numberTitle) ? String(localized: "第 \(numberTitle) 话", bundle: .module) : numberTitle
            let title = [label, longTitle].filter { !$0.isEmpty }.joined(separator: " · ")
            guard !title.isEmpty else { return nil }
            entries.append(YtDlpPlaylistEntry(index: offset + 1, title: String(title.prefix(512)), url: url))
        }
        return entries
    }

    private static func isNumber(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    static func enrich(
        _ entries: [YtDlpPlaylistEntry], source: URL, cookies: [VideoCookie] = [], load: Loader? = nil
    ) async -> [YtDlpPlaylistEntry] {
        guard let metadata = await fetch(source: source, cookies: cookies, load: load), !metadata.isEmpty else { return entries }
        return metadata
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
