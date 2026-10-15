import Foundation

public enum YtDlpPlaylist {
    public static func fetch(
        url: URL, binary: URL, cookies: [VideoCookie] = [], timeout: Duration = .seconds(20)
    ) async throws -> [YtDlpPlaylistEntry] {
        guard (VideoCookie.allows(domain: url.host ?? "", site: .bilibili) || url.host == "b23.tv"),
              ["http", "https"].contains(url.scheme ?? ""), url.user == nil, url.password == nil else {
            throw EngineError.unsupportedLink
        }
        let cookieFile = cookies.isEmpty ? nil : try YtDlpCookieFile(cookies: cookies, site: .bilibili)
        defer { try? cookieFile?.remove() }
        var arguments = ["--ignore-config", "--flat-playlist", "--yes-playlist", "-J", "--no-warnings",
                         "--no-cache-dir", "--socket-timeout", "10", "--retries", "0"]
        if let cookieFile { arguments += ["--cookies", cookieFile.url.path] }
        var listing = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = listing?.queryItems?.filter { $0.name != "p" }
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
                    let source = url.host == "b23.tv" ? (entries.first?.url ?? url) : url
                    return await YtDlpBilibiliMetadata.enrich(entries, source: source)
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
        guard let entries = object["entries"] as? [[String: Any]] else { return [] }
        guard entries.count <= 1_000 else {
            throw EngineError.invalidResponse(String(localized: "视频列表超出限制", bundle: .module))
        }
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
