import Foundation
import Testing
@testable import MuleeCore

struct DownloadRequestContextTests {
    @Test func mapsBrowserContextAndChecksum() throws {
        let checksum = try #require(DownloadChecksum.parse(String(repeating: "a", count: 64)))
        let context = DownloadRequestContext(
            referer: URL(string: "https://example.org/page"), userAgent: "Browser/1", suggestedFilename: "archive.zip",
            headers: ["Accept": "application/octet-stream", "cookie": "old=value"], cookie: "session=private"
        )
        let options = try Aria2RequestOptions.values(context: context, checksum: checksum)
        #expect(options["referer"] == .string("https://example.org/page"))
        #expect(options["user-agent"] == .string("Browser/1"))
        #expect(options["out"] == .string("archive.zip"))
        #expect(options["header"] == .array([.string("Accept: application/octet-stream"), .string("Cookie: session=private")]))
        #expect(options["checksum"] == .string("sha-256=\(checksum.digest)"))
        #expect(try Aria2RequestOptions.values(context: .init(), checksum: nil)["user-agent"] == .string(DownloadRequestContext.safariUserAgent))
    }

    @Test func cookiesNeverEnterHistoryIncludingHeaderVariants() throws {
        let context = DownloadRequestContext(headers: [
            "cOoKiE": "private-header", "Set-Cookie": "private-response", "Accept": "*/*", "Authorization": "private-auth"
        ], cookie: "private-cookie")
        let encoded = try JSONEncoder().encode(context)
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(!text.contains("private-"))
        let decoded = try JSONDecoder().decode(DownloadRequestContext.self, from: encoded)
        #expect(decoded.cookie == nil)
        #expect(decoded.headers == ["Accept": "*/*"])
        #expect(context.requestCookie == "private-cookie")
        #expect(context.withoutCookie.requestCookie == nil)
        let legacy = Data(#"{"headers":{"Cookie":"private-legacy"},"cookie":"private-field"}"#.utf8)
        #expect(try JSONDecoder().decode(DownloadRequestContext.self, from: legacy).requestCookie == nil)
        var task = DownloadTask(
            name: "archive.zip", fileExtension: "zip", kind: .http, status: .queued,
            totalBytes: nil, receivedBytes: 0, detail: .http(connections: 0),
            postDownload: PostDownloadInfo(autoExtract: false), sourceLink: "https://example.org/archive.zip"
        )
        task.requestContext = context
        #expect(!String(decoding: try JSONEncoder().encode(task), as: UTF8.self).contains("private-"))
    }

    @Test func rejectsHeaderInjectionAndFilenameTraversal() {
        for context in [
            DownloadRequestContext(userAgent: "Browser\r\nCookie: secret"),
            DownloadRequestContext(suggestedFilename: "../archive.zip"),
            DownloadRequestContext(suggestedFilename: "..\\archive.zip"),
            DownloadRequestContext(headers: ["Bad:Name": "value"]),
            DownloadRequestContext(cookie: "secret\nInjected: value")
        ] {
            #expect(throws: EngineError.self) { try context.validate() }
        }
    }
}
