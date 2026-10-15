import Foundation
import Testing
@testable import MuleeCore

@Suite struct LinkParserTorrentTests {
    @Test("本地绝对路径、file URL 和 HTTP(S) 种子链接", arguments: [
        "/tmp/Ubuntu.torrent", "/tmp/中文.torrent", "/tmp/Ubuntu Linux.torrent",
        "file:///tmp/Ubuntu.torrent", "file:///tmp/Ubuntu%20Linux.torrent",
        "file://localhost/tmp/Ubuntu.torrent", "https://example.com/Ubuntu.torrent?download=1#file",
        "http://example.com/Debian.TORRENT", "https://youtube.com/Ubuntu.torrent"
    ])
    func torrent(_ text: String) throws {
        let link = try #require(LinkParser.parse(text).first)
        let expected = text.hasPrefix("/") ? URL(fileURLWithPath: text) : try #require(URL(string: text))
        #expect(link == .torrentFile(url: expected, original: text))
        #expect(link.kind == .bittorrent)
        #expect(link.original == text)
    }

    @Test("种子链接识别看路径扩展名并保留顺序与去重")
    func mixed() throws {
        let local = "/tmp/Ubuntu.torrent"
        let remote = "https://example.com/Debian.torrent?download=1"
        let direct = "https://example.com/download?name=Ubuntu.torrent"
        #expect(LinkParser.parse("\(local)\n地址：\(remote)，密码 123\n\(local)\n\(direct)") == [
            .torrentFile(url: URL(fileURLWithPath: local), original: local),
            .torrentFile(url: try #require(URL(string: remote)), original: remote),
            .http(url: try #require(URL(string: direct)), decodedFromThunder: false, original: direct)
        ])
        #expect(LinkParser.parse("relative/Ubuntu.torrent file://remote/tmp/Ubuntu.torrent /tmp/Ubuntu.zip file:///tmp/Ubuntu.torrent/").isEmpty)
        let directory = "https://example.com/Ubuntu.torrent/"
        #expect(LinkParser.parse(directory) == [
            .http(url: try #require(URL(string: directory)), decodedFromThunder: false, original: directory)
        ])
    }
}
