import Foundation
import Testing
@testable import MuleeCore

struct ThunderLinkDecoderTests {
    // 固定样本由 Python base64.b64encode(("AA" + url + "ZZ").encode(...)) 生成。
    @Test("迅雷 HTTP、FTP、UTF-8 与 GB18030 解码", arguments: [
        ("QUFodHRwczovL2V4YW1wbGUuY29tL3NpbnRlbC1vc3QuemlwWlo=", "https://example.com/sintel-ost.zip"),
        ("QUFodHRwczovL2V4YW1wbGUuY29tL3NpbnRlbC1vc3QuemlwWlo", "https://example.com/sintel-ost.zip"),
        ("QUFodHRwczovL2V4YW1wbGUuY29tL2FaWg", "https://example.com/a"),
        ("QUFmdHA6Ly9leGFtcGxlLmNvbS9hcmNoaXZlLnppcFpa", "ftp://example.com/archive.zip"),
        ("QUFodHRwczovL2V4YW1wbGUuY29tL+i1hOaWmS56aXBaWg==", "https://example.com/资料.zip"),
        ("QUFodHRwczovL2V4YW1wbGUuY29tL9fKwc8uemlwWlo=", "https://example.com/资料.zip"),
        ("QUFodHRwczovL2V4YW1wbGUuY29tL/CfmIAuemlwWlo=", "https://example.com/😀.zip"),
        ("QUFodHRwczovL2V4YW1wbGUuY29tL_CfmIAuemlwWlo", "https://example.com/😀.zip"),
        ("QUFodHRwczovL2V4YW1wbGUuY29tL-Cgvy56aXBaWg==", "https://example.com/࠿.zip")
    ])
    func directLinks(_ payload: String, _ expectedURL: String) throws {
        let text = "thunder://\(payload)"
        let url = try #require(URL(string: expectedURL))
        #expect(ThunderLinkDecoder.decode(text) == expectedURL)
        #expect(LinkParser.parse(text) == [.http(url: url, decodedFromThunder: true, original: text)])
    }

    @Test("迅雷包裹含空格的中文 ed2k")
    func ed2k() {
        let text = "thunder://QUFlZDJrOi8vfGZpbGV86Zu+5riv5aWH6LCtIOe5geS4reeJiC5yYXJ8NjQxNzI4NTEyfDlGM0EwQzVFMTIzNDU2Nzg5MEFCQ0RFRkI3MURDMjFCfC9aWg=="
        #expect(LinkParser.parse(text) == [
            .ed2k(fileName: "雾港奇谭 繁中版.rar", size: 641728512, hash: "9F3A0C5E1234567890ABCDEFB71DC21B", original: text)
        ])
    }

    @Test("迅雷包裹磁力")
    func magnet() {
        let text = "thunder://QUFtYWduZXQ6P3h0PXVybjpidGloOmRkODI1NWVjZGM3Y2E1NWZiMGJiZjgxMzIzZDg3MDYyZGIxZjZkMWMmZG49QmlnK0J1Y2srQnVubnlaWg=="
        #expect(LinkParser.parse(text) == [
            .magnet(infoHash: "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c", displayName: "Big Buck Bunny", original: text)
        ])
    }

    @Test("迅雷包裹视频链接")
    func video() throws {
        let text = "thunder://QUFodHRwczovL2IyMy50di9hYmNaWg=="
        let url = try #require(URL(string: "https://b23.tv/abc"))
        #expect(LinkParser.parse(text) == [.video(url: url, site: .bilibili, original: text)])
    }

    @Test("迅雷可递归解码且保留最外层原文")
    func nested() throws {
        let inner = "thunder://QUFodHRwczovL2V4YW1wbGUuY29tL3NpbnRlbC1vc3QuemlwWlo="
        let text = "THUNDER://" + Data("AA\(inner)ZZ".utf8).base64EncodedString()
        let url = try #require(URL(string: "https://example.com/sintel-ost.zip"))
        #expect(LinkParser.parse(text) == [.http(url: url, decodedFromThunder: true, original: text)])
    }

    @Test("非法迅雷与不支持的解码内容被忽略", arguments: [
        "thunder://",
        "thunder://A",
        "thunder://not_base64!",
        "thunder://QUJodHRwczovL2V4YW1wbGUuY29tL2FaWg==",
        "thunder://QUFodHRwczovL2V4YW1wbGUuY29tL2FaWQ==",
        "thunder://QUFaWg==",
        "thunder:///w==",
        "thunder://QUFodHRwczovL2V4YW1wbGUuY29tL2FaWg===",
        "thunder://" + Data("AAfile:///tmp/file.zipZZ".utf8).base64EncodedString(),
        "thunder://" + Data("AAmagnet:?dn=missingZZ".utf8).base64EncodedString(),
        "thunder://" + Data("AAed2k://|file|bad|0|invalid|/ZZ".utf8).base64EncodedString()
    ])
    func invalidLinks(_ text: String) {
        #expect(LinkParser.parse(text).isEmpty)
    }

    @Test("非法链接不影响后续合法链接")
    func invalidLinksInMixedText() throws {
        let link = "https://example.com/file.zip"
        let url = try #require(URL(string: link))
        #expect(LinkParser.parse("thunder://A\n\(link)\nthunder://not_base64!") == [
            .http(url: url, decodedFromThunder: false, original: link)
        ])
    }

    @Test("原始直链与迅雷直链分别保留")
    func originalAndWrapped() throws {
        let link = "https://example.com/sintel-ost.zip"
        let wrapped = "thunder://QUFodHRwczovL2V4YW1wbGUuY29tL3NpbnRlbC1vc3QuemlwWlo="
        let url = try #require(URL(string: link))
        #expect(LinkParser.parse("\(link)\n\(wrapped)\n\(wrapped)") == [
            .http(url: url, decodedFromThunder: false, original: link),
            .http(url: url, decodedFromThunder: true, original: wrapped)
        ])
    }
}
