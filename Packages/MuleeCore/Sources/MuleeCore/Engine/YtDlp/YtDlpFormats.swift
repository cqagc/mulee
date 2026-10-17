import Foundation

public struct YtDlpFormat: Sendable, Hashable, Identifiable {
    public let id: String
    public let resolution: String
    public let codec: String
    public let size: Int64?
    public let needsLogin: Bool
    public let videoOnly: Bool

    /// 格式 ID 必须是单一标识，不接受 yt-dlp 的任意格式表达式。
    public static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 128 && id.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || "._-".utf8.contains($0)
        }
    }

    public var selector: String { videoOnly ? id + "+ba/" + id : id }
}

public enum YtDlpFormats {
    public enum ListingError: String, Error, LocalizedError {
        case failed = "无法读取视频格式，仍可跟随全局设置添加。"
        case login = "视频格式需要登录，传递登录状态后可重新打开面板；仍可跟随全局设置添加。"
        case timeout = "读取视频格式超时，仍可跟随全局设置添加。"
        public var errorDescription: String? { rawValue }
    }

    public static func fetch(
        url: URL, site: VideoSite, binary: URL, cookies: [VideoCookie] = [],
        deno: URL? = nil, timeout: Duration = .seconds(20), proxy: HTTPProxyConfiguration = .current()
    ) async throws -> [YtDlpFormat] {
        try await fetchMetadata(url: url, site: site, binary: binary, cookies: cookies, deno: deno, timeout: timeout, proxy: proxy).formats
    }

    public static func fetchMetadata(
        url: URL, site: VideoSite, binary: URL, cookies: [VideoCookie] = [],
        deno: URL? = nil, timeout: Duration = .seconds(20), proxy: HTTPProxyConfiguration = .current()
    ) async throws -> YtDlpVideoMetadata {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil else { throw EngineError.unsupportedLink }
        let source = ParsedLink.video(url: url, site: site, original: url.absoluteString)
        guard let videoURL = source.singleVideoURL else { throw EngineError.unsupportedLink }
        let cookieFile = cookies.isEmpty ? nil : try YtDlpCookieFile(cookies: cookies, site: site)
        defer { try? cookieFile?.remove() }
        var arguments = ["--ignore-config", "-J", "--skip-download", "--no-playlist", "--no-warnings",
                         "--no-cache-dir", "--socket-timeout", "10", "--retries", "0"]
        arguments += proxy.proxyArguments()
        if let cookieFile { arguments += ["--cookies", cookieFile.url.path] }
        if let deno { arguments += ["--js-runtimes", "deno:" + deno.path] }
        arguments += ["--", videoURL.absoluteString]
        let child = try YtDlpProcess(binary: binary, arguments: arguments, cleanupURL: cookieFile?.url)
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: YtDlpVideoMetadata.self) { group in
                group.addTask {
                    var data = Data()
                    for await chunk in child.output {
                        data.append(chunk)
                        guard data.count <= 8_388_608 else {
                            await child.terminate()
                            throw ListingError.failed
                        }
                    }
                    await child.finish()
                    try Task.checkCancellation()
                    guard child.status == 0 else {
                        let message = String(decoding: data, as: UTF8.self).lowercased()
                        if ["sign in", "login", "log in", "cookies", "members-only", "premium"].contains(where: message.contains) {
                            throw ListingError.login
                        }
                        throw ListingError.failed
                    }
                    return try YtDlpVideoMetadata.parse(data)
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw ListingError.timeout
                }
                defer { group.cancelAll() }
                do {
                    guard let result = try await group.next() else { throw CancellationError() }
                    return result
                } catch {
                    // 先确定超时结果再结束子进程，避免退出码抢先被误报为普通读取失败。
                    group.cancelAll()
                    await child.terminate()
                    throw error
                }
            }
        } onCancel: {
            Task { await child.terminate() }
        }
    }

    static func videoIdentity(in data: Data) -> String? {
        guard data.count <= 8_388_608,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let extractor = object["extractor_key"] as? String, !extractor.isEmpty,
              let id = object["id"] as? String, !id.isEmpty,
              extractor.utf8.count <= 128, id.utf8.count <= 512,
              !(extractor + id).unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return extractor + ":" + id
    }

    public static func parse(_ data: Data) throws -> [YtDlpFormat] {
        guard data.count <= 8_388_608,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let formats = object["formats"] as? [[String: Any]], formats.count <= 2000 else { throw ListingError.failed }
        let availability = object["availability"] as? String ?? ""
        let login = ["needs_auth", "private", "premium_only", "subscriber_only"].contains(availability)
        var seen = Set<String>()
        return formats.compactMap { format in
            guard let id = format["format_id"] as? String, YtDlpFormat.isValidID(id), seen.insert(id).inserted,
                  format["has_drm"] as? Bool != true else { return nil }
            let video = format["vcodec"] as? String ?? "none"
            let audio = format["acodec"] as? String ?? "none"
            guard video != "none" || audio != "none" else { return nil }
            let height = (format["height"] as? NSNumber)?.intValue
            let resolution = height.map { "\($0)p" } ?? (format["resolution"] as? String) ?? "仅音频"
            let bytes = (format["filesize"] as? NSNumber)?.int64Value ?? (format["filesize_approx"] as? NSNumber)?.int64Value
            return YtDlpFormat(id: id, resolution: String(resolution.prefix(80)),
                               codec: String((video == "none" ? audio : video + (audio == "none" ? "" : " / " + audio)).prefix(160)),
                               size: bytes.flatMap { $0 > 0 ? $0 : nil },
                               needsLogin: login || format["requires_auth"] as? Bool == true,
                               videoOnly: video != "none" && audio == "none")
        }
    }
}
