import Foundation
@testable import MuleeCore

final class TorrentURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "torrent.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let body: Data
        var headers: [String: String] = [:]
        switch url.lastPathComponent {
        case "header-too-large.torrent":
            headers["Content-Length"] = String(TorrentFileDownloader.maximumSize + 1)
            body = Data("d".utf8)
        case "body-too-large.torrent":
            body = Data(repeating: 100, count: TorrentFileDownloader.maximumSize + 1)
        case "invalid.torrent":
            body = Data("<html>not a torrent</html>".utf8)
        case "empty.torrent":
            body = Data()
        default:
            body = TorrentFixtures.torrent(payload: Data("Ubuntu".utf8))
            headers["Content-Length"] = String(body.count)
        }
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TorrentURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}
