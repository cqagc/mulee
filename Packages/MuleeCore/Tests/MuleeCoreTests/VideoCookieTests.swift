import Foundation
import Testing
@testable import MuleeCore

struct VideoCookieTests {
    private func cookie(domain: String = ".bilibili.com", value: String = "synthetic") -> VideoCookie {
        VideoCookie(domain: domain, path: "/", name: "test", value: value, secure: true, httpOnly: true, hostOnly: false)
    }

    @Test func netscapeFileIsPrivateAndRemoved() throws {
        let file = try YtDlpCookieFile(cookies: [cookie()], site: .bilibili)
        let url = file.url
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try String(contentsOf: url, encoding: .utf8)
        #expect(data == "# Netscape HTTP Cookie File\n#HttpOnly_.bilibili.com\tTRUE\t/\tTRUE\t0\ttest\tsynthetic\n")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try file.remove()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test(arguments: ["evil.org", ".bilibili.com.evil.org", "notbilibili.com", ".youtube.com", "..bilibili.com"])
    func rejectsOtherDomains(_ domain: String) {
        #expect(throws: (any Error).self) { try YtDlpCookieFile(cookies: [cookie(domain: domain)], site: .bilibili) }
    }

    @Test(arguments: ["secret\nforged", "secret\tforged", "secret\rforged", "secret\u{0}forged"])
    func rejectsNetscapeInjection(_ value: String) throws {
        let data = try JSONEncoder().encode(VideoCookieRequest(site: .bilibili, cookies: [cookie(value: value)]))
        #expect(throws: (any Error).self) { try VideoCookieRequest.parse(data) }
    }

    @Test func expirationAndHostOnlyFields() throws {
        let expired = VideoCookie(domain: "www.youtube.com", path: "/", name: "expired", value: "synthetic",
                                  secure: true, httpOnly: false, hostOnly: true, expirationDate: 1)
        let valid = VideoCookie(domain: "www.youtube.com", path: "/watch", name: "test", value: "synthetic",
                                secure: false, httpOnly: false, hostOnly: true, expirationDate: 4_000_000_000)
        let file = try YtDlpCookieFile(cookies: [expired, valid], site: .youtube)
        defer { try? file.remove() }
        let text = try String(contentsOf: file.url, encoding: .utf8)
        #expect(!text.contains("expired"))
        #expect(text.contains("www.youtube.com\tFALSE\t/watch\tFALSE\t4000000000\ttest\tsynthetic"))
    }

    @Test func handoffUsesPrivateFilesAndClaimsIndependently() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let request = VideoCookieRequest(site: .bilibili, cookies: [cookie()])
        try VideoCookieHandoff.save(request, directory: root)
        let first = try #require(try VideoCookieHandoff.take(site: .bilibili, directory: root))
        try VideoCookieHandoff.save(request, directory: root)
        try FileManager.default.removeItem(at: first.file)
        let second = try #require(try VideoCookieHandoff.take(site: .bilibili, directory: root))
        #expect(second.request.cookies == request.cookies)
        #expect(try VideoCookieHandoff.take(site: .bilibili, directory: root) == nil)
    }
}
