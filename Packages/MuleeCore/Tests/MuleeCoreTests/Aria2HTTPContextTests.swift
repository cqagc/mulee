import Foundation
import Testing
@testable import MuleeCore

struct Aria2HTTPContextTests {
    @Test func credentialHostComparisonIncludesPortAndIgnoresCase() throws {
        let original = try #require(URL(string: "https://EXAMPLE.org/file"))
        #expect(HTTPResourceProbe.sameHost(original, URL(string: "https://example.org:443/other")!))
        #expect(!HTTPResourceProbe.sameHost(original, URL(string: "https://example.org:8443/other")!))
        #expect(!HTTPResourceProbe.sameHost(original, URL(string: "https://other.example.org/file")!))
    }

    @Test(arguments: [(401, HTTPDownloadFailure.needsLogin), (403, .expiredLink), (404, .missingFile), (410, .expiredLink)])
    func humanReadableHTTPFailures(_ status: Int, _ expected: HTTPDownloadFailure) {
        #expect(HTTPDownloadFailure.classify(statusCode: status) == expected)
        #expect(Aria2ErrorDescriptions.message(for: "22", detail: "status=\(status); https://example.org/?token=private") == expected.localizedDescription)
    }

    @Test func detectsWebPagesAndRangeResourceSize() throws {
        let url = try #require(URL(string: "https://example.org/archive.zip"))
        let page = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html; charset=utf-8"]))
        #expect(throws: HTTPDownloadFailure.webPage) { try HTTPResourceProbe.identity(response: page, expectsHTML: false) }
        let range = try #require(HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil, headerFields: [
            "Content-Length": "1", "Content-Range": "bytes 0-0/4096", "ETag": "\"v1\""
        ]))
        let identity = try HTTPResourceProbe.identity(response: range, expectsHTML: false)
        #expect(identity.size == 4096)
        #expect(identity.etag == "\"v1\"")
    }

    @Test func emptyRangeResponseUsesResourceSizeInsteadOfErrorBodyLength() throws {
        let url = try #require(URL(string: "https://example.org/empty.bin"))
        let response = try #require(HTTPURLResponse(url: url, statusCode: 416, httpVersion: nil, headerFields: [
            "Content-Range": "bytes */0", "Content-Length": "200", "Content-Type": "text/html", "ETag": "empty"
        ]))
        let identity = try HTTPResourceProbe.identity(response: response, expectsHTML: false)
        #expect(identity.size == 0)
        #expect(identity.etag == "empty")
        #expect(identity.contentType == nil)
    }

    @Test(arguments: ["bytes */1", "bytes */*", "bytes 0-0/0", ""])
    func otherUnsatisfiedRangesStillFail(_ range: String) throws {
        let url = try #require(URL(string: "https://example.org/file.bin"))
        let response = try #require(HTTPURLResponse(url: url, statusCode: 416, httpVersion: nil, headerFields: ["Content-Range": range]))
        #expect(throws: HTTPDownloadFailure.status(416)) { try HTTPResourceProbe.identity(response: response, expectsHTML: false) }
    }

    @Test func replacementRequiresSizeAndAvailableETagToMatch() throws {
        #expect(Aria2ErrorDescriptions.message(for: "7") == HTTPDownloadFailure.resourceChanged.localizedDescription)
        let original = HTTPResourceIdentity(size: 4096, etag: "\"v1\"")
        try original.validateReplacement(.init(size: 4096, etag: "\"v1\""))
        #expect(throws: HTTPDownloadFailure.resourceChanged) { try original.validateReplacement(.init(size: 4097, etag: "\"v1\"")) }
        #expect(throws: HTTPDownloadFailure.resourceChanged) { try original.validateReplacement(.init(size: 4096, etag: "\"v2\"")) }
        #expect(throws: HTTPDownloadFailure.unknownIdentity) { try original.validateReplacement(.init(size: 4096)) }
        #expect(throws: HTTPDownloadFailure.unknownIdentity) { try original.validateReplacement(.init(size: nil)) }
        #expect(throws: HTTPDownloadFailure.webPage) {
            try HTTPResourceIdentity(size: 4096).validateReplacement(.init(size: 4096, contentType: "text/html"))
        }
    }

    @Test func retryDefaults() throws {
        let root = URL(fileURLWithPath: "/tmp/aria2-context")
        let configuration = Aria2Configuration(stateDirectory: root, port: 34567, secret: "test", options: EngineOptions(downloadDirectory: root))
        let text = try configuration.contents()
        for value in ["max-tries=5", "retry-wait=5", "lowest-speed-limit=1K", "connect-timeout=30", "timeout=60", "user-agent=\(DownloadRequestContext.safariUserAgent)"] {
            #expect(text.contains(value + "\n"))
        }
    }
}
