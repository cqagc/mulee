import Foundation
import MuleeCore

/// 浏览器入口只携带远程链接；本地种子仅从系统打开事件进入。
struct OpenURLRequest {
    static let maximumLinks = 200
    static let maximumBytes = 1_048_576

    var links: [ParsedLink]
    var sourcePageURL: URL?
    var password: String?
    var requestContext = DownloadRequestContext()
    var cookieToken: String?

    static func parse(_ url: URL, detectPagePassword: Bool) -> Self? {
        guard url.absoluteString.utf8.count <= maximumBytes else { return nil }
        if url.scheme?.lowercased() == "mulee" {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  components.host == "add", components.path.isEmpty,
                  components.user == nil, components.password == nil, components.port == nil,
                  components.fragment == nil else { return nil }
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%20")
            let items = components.queryItems ?? []
            let values = items.filter { $0.name == "url" }.compactMap(\.value)
            guard !values.isEmpty, values.count <= maximumLinks else { return nil }
            var links: [ParsedLink] = []
            for value in values {
                let scheme = value.prefix { $0 != ":" }.lowercased()
                guard ["http", "https", "ftp", "magnet", "ed2k", "thunder"].contains(scheme) else { return nil }
                let parsed = LinkParser.parse(value)
                guard !parsed.isEmpty, parsed.allSatisfy(isRemote) else { return nil }
                links += parsed
                guard links.count <= maximumLinks else { return nil }
            }
            let tokens = items.filter { $0.name == "token" }
            guard tokens.count <= 1 else { return nil }
            let cookieToken = tokens.first?.value
            if !tokens.isEmpty {
                guard let cookieToken, DownloadCookieRequest.isValidToken(cookieToken), links.count == 1 else { return nil }
            }
            let referrer = items.first { $0.name == "referrer" }?.value.flatMap(URL.init(string:))
            let source = referrer.flatMap { url in
                ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil
                    && url.user == nil && url.password == nil ? url : nil
            }
            let text = items.first { $0.name == "text" }?.value ?? ""
            let context = DownloadRequestContext(
                referer: source, userAgent: items.first { $0.name == "ua" }?.value,
                suggestedFilename: items.first { $0.name == "filename" }?.value
            )
            guard (try? context.validate()) != nil else { return nil }
            return Self(
                links: links, sourcePageURL: source, password: pagePassword(in: text, enabled: detectPagePassword),
                requestContext: context, cookieToken: cookieToken
            )
        }
        guard url.isFileURL ? HTTPMetalink.isDownloadFile(url)
            : ["magnet", "ed2k", "thunder"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        var text = url.absoluteString
        if url.scheme?.lowercased() == "ed2k" {
            text = text.replacingOccurrences(of: "%7C", with: "|", options: .caseInsensitive)
        }
        let links = LinkParser.parse(text)
        guard !links.isEmpty, url.isFileURL || links.allSatisfy(isRemote) else { return nil }
        return Self(links: links)
    }

    static func pagePassword(in text: String, enabled: Bool) -> String? {
        enabled ? PasswordTextParser.password(in: text) : nil
    }

    static func isRemote(_ link: ParsedLink) -> Bool {
        if case .torrentFile(let url, _) = link { return !url.isFileURL }
        if case .http(let url, _, _) = link { return !url.isFileURL }
        return true
    }
}
