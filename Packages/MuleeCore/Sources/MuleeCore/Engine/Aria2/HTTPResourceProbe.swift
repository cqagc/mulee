import Foundation

public enum HTTPResourceProbe {
    static func sameHost(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let host = lhs.host?.lowercased(), host == rhs.host?.lowercased() else { return false }
        let port: (URL) -> Int? = { $0.port ?? ($0.scheme?.lowercased() == "https" ? 443 : 80) }
        return port(lhs) == port(rhs)
    }

    @concurrent
    public static func validateDownloadedFile(_ file: URL) async throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 1024) ?? Data()
        let prefix = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{FEFF}", with: "").lowercased()
        if prefix.hasPrefix("<!doctype html") || prefix.hasPrefix("<html") || prefix.hasPrefix("<head>") {
            throw HTTPDownloadFailure.webPage
        }
    }

    public static func inspect(
        _ url: URL, context: DownloadRequestContext = .init(), expectsHTML: Bool = false
    ) async throws -> HTTPResourceIdentity {
        try context.validate()
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else { throw EngineError.unsupportedLink }
        let response = try await inspectResponse(url, context: context)
        return try identity(response: response, expectsHTML: expectsHTML)
    }

    /// aria2 的通用 header 会跟随重定向；先解析最终地址，再按原主机限制凭据。
    static func prepareDownload(_ url: URL, context: DownloadRequestContext) async throws -> (url: URL, context: DownloadRequestContext) {
        try context.validate()
        let hasCredentials = context.requestCookie != nil || context.headers.keys.contains {
            ["authorization", "proxy-authorization"].contains($0.lowercased())
        }
        guard hasCredentials, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return (url, context) }
        let response = try await inspectResponse(url, context: context)
        if let failure = HTTPDownloadFailure.classify(statusCode: response.statusCode) { throw failure }
        guard let finalURL = response.url else { throw EngineError.unsupportedLink }
        var scoped = context
        if !sameHost(url, finalURL) || url.scheme?.lowercased() != finalURL.scheme?.lowercased() {
            scoped = context.withoutCookie
            scoped.headers = scoped.headers.filter { !["authorization", "proxy-authorization"].contains($0.key.lowercased()) }
        }
        return (finalURL, scoped)
    }

    private static func inspectResponse(_ url: URL, context: DownloadRequestContext) async throws -> HTTPURLResponse {
        var response = try await response(url, context: context, method: "HEAD")
        // 签名 GET 链接可能拒绝 HEAD；用一字节 Range 确认，不能直接误报过期。
        if [403, 405, 501].contains(response.statusCode)
            || ((200..<300).contains(response.statusCode) && response.value(forHTTPHeaderField: "Content-Length") == nil) {
            response = try await self.response(url, context: context, method: "GET")
        }
        return response
    }

    static func identity(response: HTTPURLResponse, expectsHTML: Bool) throws -> HTTPResourceIdentity {
        if let failure = HTTPDownloadFailure.classify(statusCode: response.statusCode) { throw failure }
        let type = response.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        if type == "text/html", !expectsHTML { throw HTTPDownloadFailure.webPage }
        let size: Int64?
        if response.statusCode == 206 {
            let range = response.value(forHTTPHeaderField: "Content-Range") ?? ""
            size = range.split(separator: "/").last.flatMap { Int64($0) }
        } else {
            size = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init)
        }
        return HTTPResourceIdentity(size: size.flatMap { $0 >= 0 ? $0 : nil }, etag: response.value(forHTTPHeaderField: "ETag"), contentType: type)
    }

    private static func response(_ url: URL, context: DownloadRequestContext, method: String) async throws -> HTTPURLResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration, delegate: HTTPProbeRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        for (key, value) in context.withoutCookie.headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue(context.userAgent ?? request.value(forHTTPHeaderField: "User-Agent") ?? DownloadRequestContext.safariUserAgent, forHTTPHeaderField: "User-Agent")
        if let referer = context.referer { request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
        request.setValue(context.requestCookie, forHTTPHeaderField: "Cookie")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if method == "GET" { request.setValue("bytes=0-0", forHTTPHeaderField: "Range") }
        // 只等响应头，即使服务器忽略 Range 返回整文件，也不把正文读入内存。
        let (_, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw EngineError.invalidResponse("无法读取 HTTP 响应") }
        return response
    }
}

private final class HTTPProbeRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let destination = request.url, ["http", "https"].contains(destination.scheme?.lowercased() ?? ""),
              destination.user == nil, destination.password == nil else { return nil }
        var request = request
        if response.url.map({ !HTTPResourceProbe.sameHost($0, destination) || $0.scheme?.lowercased() != destination.scheme?.lowercased() }) ?? true {
            request.setValue(nil, forHTTPHeaderField: "Cookie")
            request.setValue(nil, forHTTPHeaderField: "Authorization")
            request.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
        }
        return request
    }
}
