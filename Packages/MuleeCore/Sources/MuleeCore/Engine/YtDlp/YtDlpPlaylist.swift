import Foundation

public enum YtDlpPlaylist {
    /// nil 表示接口不适用或失败，空数组表示已确认没有分 P 或合集。
    public static func fetchMetadata(
        url: URL, cookies: [VideoCookie] = [],
        load: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil
    ) async -> [YtDlpPlaylistEntry]? {
        await YtDlpBilibiliMetadata.fetch(source: url, cookies: cookies, load: load)
    }

    public static func fetch(
        url: URL, binary: URL, cookies: [VideoCookie] = [], timeout: Duration = .seconds(20)
    ) async throws -> [YtDlpPlaylistEntry] {
        let host = url.host?.lowercased() ?? ""
        let site: VideoSite = VideoCookie.allows(domain: host, site: .youtube) || host == "youtu.be" ? .youtube : .bilibili
        guard (VideoCookie.allows(domain: host, site: site) || host == "b23.tv" || host == "youtu.be"),
              ["http", "https"].contains(url.scheme ?? ""), url.user == nil, url.password == nil else {
            throw EngineError.unsupportedLink
        }
        let cookieFile = cookies.isEmpty ? nil : try YtDlpCookieFile(cookies: cookies, site: site)
        defer { try? cookieFile?.remove() }
        var arguments = ["--ignore-config", "--flat-playlist", "--yes-playlist", "-J", "--no-warnings",
                         "--no-cache-dir", "--socket-timeout", "10", "--retries", "0"]
        if site == .youtube { arguments += ["--playlist-end", "1000"] }
        if let cookieFile { arguments += ["--cookies", cookieFile.url.path] }
        var listing = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = listing?.queryItems?.filter { site == .youtube ? !["v", "index", "start_radio"].contains($0.name) : $0.name != "p" }
        if site == .youtube {
            listing?.host = "www.youtube.com"
            listing?.path = "/playlist"
        }
        listing?.queryItems = query
        arguments += ["--", listing?.url?.absoluteString ?? url.absoluteString]
        let child = try YtDlpProcess(binary: binary, arguments: arguments, cleanupURL: cookieFile?.url)
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: [YtDlpPlaylistEntry].self) { group in
                group.addTask {
                    var data = Data()
                    for await chunk in child.output {
                        data.append(chunk)
                        guard data.count <= 4_194_304 else {
                            await child.terminate()
                            throw EngineError.invalidResponse(String(localized: "视频列表超出限制", bundle: .module))
                        }
                    }
                    await child.finish()
                    try Task.checkCancellation()
                    guard child.status == 0 else {
                        throw EngineError.invalidResponse(String(localized: "无法获取视频列表，请稍后重试", bundle: .module))
                    }
                    let entries = try parse(data, source: url)
                    if site == .youtube { return entries }
                    let source = url.host == "b23.tv" ? (entries.first?.url ?? url) : url
                    return await YtDlpBilibiliMetadata.enrich(entries, source: source, cookies: cookies)
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    await child.terminate()
                    throw EngineError.invalidResponse(String(localized: "获取视频列表超时", bundle: .module))
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw CancellationError() }
                return result
            }
        } onCancel: {
            Task { await child.terminate() }
        }
    }

    public static func parse(_ data: Data, source: URL) throws -> [YtDlpPlaylistEntry] {
        guard data.count <= 4_194_304,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EngineError.invalidResponse(String(localized: "视频列表格式无效", bundle: .module))
        }
        guard let rawEntries = object["entries"] as? [Any] else { return [] }
        guard rawEntries.count <= 1_000 else {
            throw EngineError.invalidResponse(String(localized: "视频列表超出限制", bundle: .module))
        }
        if VideoCookie.allows(domain: source.host?.lowercased() ?? "", site: .youtube) || source.host?.lowercased() == "youtu.be" {
            let playlistTitle = (object["title"] as? String).map { String($0.prefix(512)) }
            var seen = Set<URL>()
            return rawEntries.enumerated().compactMap { offset, value in
                guard let entry = value as? [String: Any], let id = entry["id"] as? String,
                      let candidate = URL(string: "https://www.youtube.com/watch?v=" + id) else { return nil }
                let link = ParsedLink.video(url: candidate, site: .youtube, original: candidate.absoluteString)
                guard link.youtubeVideoID == id, let url = link.singleVideoURL, seen.insert(url).inserted else { return nil }
                let duration = (entry["duration"] as? NSNumber)?.doubleValue
                let extractor = (entry["extractor_key"] as? String) ?? (entry["ie_key"] as? String)
                return YtDlpPlaylistEntry(
                    index: offset + 1, title: String((entry["title"] as? String ?? "").prefix(512)),
                    url: url, site: .youtube, duration: duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil },
                    playlistTitle: playlistTitle, videoIdentity: extractor.map { $0 + ":" + id }
                )
            }
        }
        guard let entries = rawEntries as? [[String: Any]] else { return [] }
        var seen = Set<URL>()
        return entries.enumerated().compactMap { offset, entry in
            let index = offset + 1
            let raw = (entry["webpage_url"] as? String) ?? (entry["url"] as? String)
            var components = raw.flatMap(URLComponents.init(string:))
            if components?.host == nil { components = URLComponents(url: source, resolvingAgainstBaseURL: false) }
            guard var components, VideoCookie.allows(domain: components.host ?? "", site: .bilibili),
                  ["http", "https"].contains(components.scheme ?? ""), components.user == nil, components.password == nil else { return nil }
            // 同一 BV 的多 P 通过 p 定位；合集中的其他 BV 保留它们自己的地址。
            if components.path == source.path || raw == nil || components.queryItems?.contains(where: { $0.name == "p" }) == true {
                var query = components.queryItems?.filter { $0.name != "p" } ?? []
                let existing = components.queryItems?.first(where: { $0.name == "p" })?.value.flatMap(Int.init)
                query.append(URLQueryItem(name: "p", value: String(existing ?? index)))
                components.queryItems = query
            }
            components.fragment = nil
            guard let url = components.url, seen.insert(url).inserted else { return nil }
            let title = String((entry["title"] as? String ?? "").prefix(512))
            return YtDlpPlaylistEntry(index: index, title: title, url: url)
        }
    }
}
