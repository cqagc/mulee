import Foundation

public enum HTTPMetalink {
    public static func recognizes(_ url: URL) -> Bool {
        !url.hasDirectoryPath && ["metalink", "meta4"].contains(url.pathExtension.lowercased())
    }

    static func load(_ url: URL, proxy: HTTPProxyConfiguration) async throws -> Data {
        let maximumBytes = 4 * 1024 * 1024
        if url.isFileURL {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
            guard !data.isEmpty, data.count <= maximumBytes else { throw EngineError.invalidResponse(String(localized: "Metalink 文件为空或超过 4 MB", bundle: .module)) }
            return data
        }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else {
            throw EngineError.unsupportedLink
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = proxy.sessionProxyDictionary
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration, delegate: HTTPProbeRedirectDelegate(proxy: proxy), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: url)
        guard let response = response as? HTTPURLResponse else { throw EngineError.invalidResponse(String(localized: "无法读取 Metalink", bundle: .module)) }
        if let failure = HTTPDownloadFailure.classify(statusCode: response.statusCode) { throw failure }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw EngineError.invalidResponse(String(localized: "Metalink 文件超过 4 MB", bundle: .module)) }
            data.append(byte)
        }
        return data
    }

    public static func isDownloadFile(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "torrent" || recognizes(url)
    }
}
