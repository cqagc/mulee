import Foundation
import Testing
@testable import MuleeCore

struct VideoCookieRequestEmptyTests {
    @Test(arguments: [VideoSite.bilibili, .youtube])
    func emptyRecordsRemainReadableButCannotBeSaved(_ site: VideoSite) throws {
        let data = try JSONEncoder().encode(VideoCookieRequest(site: site, cookies: []))
        let request = try VideoCookieRequest.parse(data)
        #expect(request.cookies.isEmpty)
        #expect(throws: EngineError.self) { try request.validateForSaving() }
    }

    @Test(arguments: ["test", "sessdata"])
    func bilibiliRequiresSESSDATA(_ name: String) throws {
        let cookie = VideoCookie(domain: ".bilibili.com", path: "/", name: name, value: "synthetic",
                                 secure: true, httpOnly: true, hostOnly: false)
        let data = try JSONEncoder().encode(VideoCookieRequest(site: .bilibili, cookies: [cookie]))
        let request = try VideoCookieRequest.parse(data)
        #expect(throws: EngineError.self) { try request.validateForSaving() }
    }

    @Test(arguments: [VideoSite.bilibili, .youtube])
    func acceptsRequiredCookies(_ site: VideoSite) throws {
        let cookie = VideoCookie(domain: site == .bilibili ? ".bilibili.com" : ".youtube.com", path: "/",
                                 name: site == .bilibili ? "SESSDATA" : "test", value: "synthetic",
                                 secure: true, httpOnly: true, hostOnly: false)
        let data = try JSONEncoder().encode(VideoCookieRequest(site: site, cookies: [cookie]))
        try VideoCookieRequest.parse(data).validateForSaving()
    }
}
