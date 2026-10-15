import Foundation
import Testing
@testable import MuleeCore

struct LinkParserTests {
    @Test("原型中的四种链接一次粘贴，补全原型省略的 ed2k 哈希")
    func prototypeLinks() throws {
        let magnet = "magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c&dn=Big+Buck+Bunny"
        let ed2k = "ed2k://|file|超魔法大戰 繁中版.rar|641728512|9F3A0C5E1234567890ABCDEFB71DC21B|/"
        let thunder = "thunder://QUFodHRwczovL2V4YW1wbGUuY29tL3NpbnRlbC1vc3QuemlwWlo="
        let video = "https://www.bilibili.com/video/BV1xx411c7XX"
        let archiveURL = try #require(URL(string: "https://example.com/sintel-ost.zip"))
        let videoURL = try #require(URL(string: video))

        #expect(LinkParser.parse([magnet, ed2k, thunder, video].joined(separator: "\n")) == [
            .magnet(infoHash: "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c", displayName: "Big Buck Bunny", original: magnet),
            .ed2k(fileName: "超魔法大戰 繁中版.rar", size: 641728512, hash: "9F3A0C5E1234567890ABCDEFB71DC21B", original: ed2k),
            .http(url: archiveURL, decodedFromThunder: true, original: thunder),
            .video(url: videoURL, site: .bilibili, original: video)
        ])
    }

    @Test("ed2k 名称解码、空格与附加字段", arguments: [
        ("超魔法大戰 繁中版.rar", "超魔法大戰 繁中版.rar", ""),
        ("%E4%B8%AD%E6%96%87%20%E6%96%87%E4%BB%B6.rar", "中文 文件.rar", ""),
        ("a+b%2Bc%7Cd%25.rar", "a+b+c|d%.rar", "h=ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"),
        ("name\twith space.rar", "name\twith space.rar", "p=part-hash|sources,127.0.0.1:4662")
    ])
    func ed2kNames(_ encodedName: String, _ expectedName: String, _ extra: String) {
        let suffix = extra.isEmpty ? "" : "\(extra)|"
        let text = "ed2k://|file|\(encodedName)|641728512|9f3a0c5e1234567890abcdefb71dc21b|\(suffix)/"

        #expect(LinkParser.parse(text) == [
            .ed2k(fileName: expectedName, size: 641728512, hash: "9F3A0C5E1234567890ABCDEFB71DC21B", original: text)
        ])
    }

    @Test("ed2k 正整数大小边界", arguments: ["1", "0001", "9223372036854775807"])
    func ed2kSizes(_ size: String) throws {
        let text = "ed2k://|file|file.zip|\(size)|0123456789abcdef0123456789abcdef|/"
        let expectedSize = try #require(Int64(size))
        #expect(LinkParser.parse(text) == [
            .ed2k(fileName: "file.zip", size: expectedSize, hash: "0123456789ABCDEF0123456789ABCDEF", original: text)
        ])
    }

    @Test("非法 ed2k 被忽略", arguments: [
        "ed2k://|server|127.0.0.1|4662|/",
        "ed2k://|file||1|0123456789abcdef0123456789abcdef|/",
        "ed2k://|file|bad%ZZ.rar|1|0123456789abcdef0123456789abcdef|/",
        "ed2k://|file|file.rar|0|0123456789abcdef0123456789abcdef|/",
        "ed2k://|file|file.rar|-1|0123456789abcdef0123456789abcdef|/",
        "ed2k://|file|file.rar|+1|0123456789abcdef0123456789abcdef|/",
        "ed2k://|file|file.rar|1.5|0123456789abcdef0123456789abcdef|/",
        "ed2k://|file|file.rar||0123456789abcdef0123456789abcdef|/",
        "ed2k://|file|file.rar|9223372036854775808|0123456789abcdef0123456789abcdef|/",
        "ed2k://|file|file.rar|１２|0123456789abcdef0123456789abcdef|/",
        "ed2k://|file|file.rar|1|0123456789abcdef0123456789abcdeg|/",
        "ed2k://|file|file.rar|1|0123456789abcdef0123456789abcde|/",
        "ed2k://|file|file.rar|1|0123456789abcdef0123456789abcdef0|/",
        "ed2k://|file|超魔法大戰 繁中版.rar|641728512|9F3A0C5E…B71DC21B|/",
        "ed2k://|file|file.rar|1|0123456789abcdef0123456789abcdef|"
    ])
    func invalidEd2k(_ text: String) {
        #expect(LinkParser.parse(text).isEmpty)
    }

    @Test("磁力哈希统一为小写十六进制", arguments: [
        ("DD8255ECDC7CA55FB0BBF81323D87062DB1F6D1C", "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c"),
        ("dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c", "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c"),
        ("3WBFL3G4PSSV7MF37AJSHWDQMLNR63I4", "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c"),
        ("3wbfl3g4pssv7mf37ajshwdqmlnr63i4", "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c"),
        ("3wBfL3G4pSsV7mF37aJsHwDqMlNr63i4", "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c"),
        ("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "0000000000000000000000000000000000000000"),
        ("77777777777777777777777777777777", "ffffffffffffffffffffffffffffffffffffffff")
    ])
    func magnetHashes(_ hash: String, _ expected: String) {
        let text = "magnet:?xt=urn:btih:\(hash)"
        #expect(LinkParser.parse(text) == [.magnet(infoHash: expected, displayName: nil, original: text)])
    }

    @Test("磁力参数顺序和名称百分号解码", arguments: [
        ("dn=Big+Buck+Bunny&xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c", "Big Buck Bunny"),
        ("xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c&dn=%E4%B8%AD%E6%96%87+%2B%20%26%3D", "中文 + &="),
        ("dn=&xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c", ""),
        ("xt=urn:sha1:ignored&dn=Name&xt=urn%3Abtih%3Add8255ecdc7ca55fb0bbf81323d87062db1f6d1c", "Name"),
        ("xt=urn:btih:invalid&xt=URN:BTIH:DD8255ECDC7CA55FB0BBF81323D87062DB1F6D1C&dn=Name", "Name")
    ])
    func magnetNames(_ query: String, _ expected: String) {
        let text = "magnet:?\(query)"
        #expect(LinkParser.parse(text) == [
            .magnet(infoHash: "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c", displayName: expected, original: text)
        ])
    }

    @Test("没有合法 BTIH 的磁力链接被忽略", arguments: [
        "magnet:?dn=No+Hash",
        "magnet:?xt=urn:btmh:1220abcdef",
        "magnet:?xt=urn:sha1:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c",
        "magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1",
        "magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1ca",
        "magnet:?xt=urn:btih:gd8255ecdc7ca55fb0bbf81323d87062db1f6d1c",
        "magnet:?xt=urn:btih:3WBFL3G4PSSV7MF37AJSHWDQMLNR63I",
        "magnet:?xt=urn:btih:3WBFL3G4PSSV7MF37AJSHWDQMLNR63I4A",
        "magnet:?xt=urn:btih:0WBFL3G4PSSV7MF37AJSHWDQMLNR63I4",
        "magnet:?xt=urn:btih:1WBFL3G4PSSV7MF37AJSHWDQMLNR63I4",
        "magnet:?xt=urn:btih:8WBFL3G4PSSV7MF37AJSHWDQMLNR63I4",
        "magnet:?xt=urn:btih:ßAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    ])
    func invalidMagnet(_ text: String) {
        #expect(LinkParser.parse(text).isEmpty)
    }

    @Test("视频站按 host 分类", arguments: [
        ("https://bilibili.com/video/1", VideoSite.bilibili),
        ("https://www.bilibili.com/video/1", .bilibili),
        ("http://a.b.bilibili.com/video/1", .bilibili),
        ("https://b23.tv/abc", .bilibili),
        ("https://youtube.com/watch?v=abc", .youtube),
        ("https://www.youtube.com/watch?v=abc", .youtube),
        ("https://m.youtube.com/watch?v=abc", .youtube),
        ("https://youtu.be/abc", .youtube),
        ("HTTPS://WWW.YOUTUBE.COM/watch?v=abc", .youtube)
    ])
    func videoSites(_ text: String, _ site: VideoSite) throws {
        let url = try #require(URL(string: text))
        #expect(LinkParser.parse(text) == [.video(url: url, site: site, original: text)])
    }

    @Test("其他网站与 FTP 为直链", arguments: [
        "https://example.com/file.zip?x=1&y=2#download",
        "http://localhost:8080/file.zip",
        "http://127.0.0.1/file.zip",
        "https://[::1]/file.zip",
        "https://[::1]",
        "https://example.com/file(1).zip",
        "https://example.com/file(1)",
        "ftp://user:password@example.com/archive.zip",
        "ftp://youtube.com/archive.zip",
        "https://notbilibili.com/file.zip",
        "https://bilibili.com.evil.example/file.zip",
        "https://youtube.com@evil.example/file.zip",
        "https://evilyoutube.com/file.zip",
        "https://b23.tv.evil.example/file.zip",
        "https://youtu.be.evil.example/file.zip",
        "https://example.com/中文文件.zip"
    ])
    func directLinks(_ text: String) throws {
        let url = try #require(URL(string: text))
        #expect(LinkParser.parse(text) == [.http(url: url, decodedFromThunder: false, original: text)])
    }

    @Test("中文句子与 URL 尾部标点", arguments: [
        "，", "。", "；", "：", "！", "？", "、", "…", ",", ".", ";", ":", "!", "?",
        "）", "」", "』", "】", "”", "’", ")", "]", "}", "》", "〉", ">", "\"", "'", "）。"
    ])
    func surroundingProse(_ punctuation: String) throws {
        let link = "https://example.com/archive.zip"
        let url = try #require(URL(string: link))
        #expect(LinkParser.parse("下载地址：\(link)\(punctuation)") == [
            .http(url: url, decodedFromThunder: false, original: link)
        ])
    }

    // 全角句读（，。；：！？、…）一律视为链接结束，见 LinkParserShareTextTests；这里只覆盖括号、引号和半角标点。
    @Test("URL 内部的括号引号和半角标点不截断", arguments: [
        "报告（最终版）.zip", "报告（最终版）", "报告(最终版)", "报告[最终版]", "报告{最终版}",
        "报告「最终版」", "报告『最终版』", "报告【最终版】", "报告“最终版”", "报告‘最终版’",
        "报告《最终版》", "报告〈最终版〉", "报告<最终版>", "报告\"最终版\"", "报告'最终版'",
        "报告,.;:!?最终版.zip", "报告（最终版）?name=中文"
    ])
    func punctuationInsideURL(_ path: String) throws {
        let link = "https://example.com/\(path)"
        let url = try #require(URL(string: link))

        #expect(LinkParser.parse("下载地址\(link)") == [
            .http(url: url, decodedFromThunder: false, original: link)
        ])
    }

    @Test("仅移除多余的尾部右括号引号", arguments: [
        ("报告（最终版））。", "报告（最终版）"),
        ("报告(最终版))!", "报告(最终版)"),
        ("报告【最终版】】；", "报告【最终版】"),
        ("报告“最终版””，", "报告“最终版”"),
        ("报告'最终版''.", "报告'最终版'")
    ])
    func unmatchedTrailingClosers(_ path: String, _ expectedPath: String) throws {
        let link = "https://example.com/\(expectedPath)"
        let url = try #require(URL(string: link))

        #expect(LinkParser.parse("https://example.com/\(path)") == [
            .http(url: url, decodedFromThunder: false, original: link)
        ])
    }

    // 半角逗号是合法的 URL 字符，无法和说明文字区分，所以只覆盖全角写法。
    @Test("中文紧贴协议头且后接密码说明", arguments: ["，密码", "，密码：", "，提取码："])
    func linkImmediatelyAfterChinese(_ label: String) throws {
        let link = "https://a.com/x.zip"
        let url = try #require(URL(string: link))

        #expect(LinkParser.parse("下载地址\(link)\(label) 123") == [
            .http(url: url, decodedFromThunder: false, original: link)
        ])
    }

    @Test("任意空白切分并保持原顺序", arguments: [" ", "\t", "\n", "\r\n", "\u{2003}", "\u{00a0}"])
    func whitespace(_ separator: String) throws {
        let first = "https://example.com/first.zip"
        let second = "ftp://example.com/second.zip"
        let firstURL = try #require(URL(string: first))
        let secondURL = try #require(URL(string: second))
        #expect(LinkParser.parse("\(separator)\(first)\(separator)\(second)\(separator)") == [
            .http(url: firstURL, decodedFromThunder: false, original: first),
            .http(url: secondURL, decodedFromThunder: false, original: second)
        ])
    }

    @Test("多个 ed2k 与中文句子混排时顺序不变")
    func mixedEd2kOrder() throws {
        let first = "https://example.com/first.zip"
        let ed2k = "ed2k://|file|中文 文件.rar|1|0123456789abcdef0123456789abcdef|/"
        let secondEd2k = "ed2k://|file|第二个 文件.rar|2|abcdef0123456789abcdef0123456789|/"
        let last = "https://youtu.be/abc"
        let firstURL = try #require(URL(string: first))
        let lastURL = try #require(URL(string: last))
        let text = "先下载：\(first)，电驴：\(ed2k)；\(secondEd2k)\n最后看：\(last)。"
        #expect(LinkParser.parse(text) == [
            .http(url: firstURL, decodedFromThunder: false, original: first),
            .ed2k(fileName: "中文 文件.rar", size: 1, hash: "0123456789ABCDEF0123456789ABCDEF", original: ed2k),
            .ed2k(fileName: "第二个 文件.rar", size: 2, hash: "ABCDEF0123456789ABCDEF0123456789", original: secondEd2k),
            .video(url: lastURL, site: .youtube, original: last)
        ])
    }

    @Test("缺少终止符的 ed2k 不吞掉后续合法链接")
    func unterminatedEd2k() {
        let broken = "ed2k://|file|broken file.rar|1|0123456789abcdef0123456789abcdef"
        let valid = "ed2k://|file|valid file.rar|2|abcdef0123456789abcdef0123456789|/"
        #expect(LinkParser.parse("\(broken) \(valid)") == [
            .ed2k(fileName: "valid file.rar", size: 2, hash: "ABCDEF0123456789ABCDEF0123456789", original: valid)
        ])
    }

    @Test("完全相同的结果仅保留第一次出现")
    func duplicates() {
        let links = [
            "https://example.com/file.zip",
            "magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c",
            "ed2k://|file|中文 文件.rar|1|0123456789abcdef0123456789abcdef|/",
            "thunder://QUFodHRwczovL2V4YW1wbGUuY29tL3NpbnRlbC1vc3QuemlwWlo=",
            "https://youtu.be/abc"
        ]
        let repeated = (links + links.reversed() + links).joined(separator: "\n")
        let parsed = LinkParser.parse(links.joined(separator: "\n"))
        #expect(parsed.count == 5)
        #expect(LinkParser.parse(repeated) == parsed)
    }

    @Test("原文不同的结果不属于完全相同")
    func distinctOriginals() {
        let lower = "magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c"
        let upper = "magnet:?xt=urn:btih:DD8255ECDC7CA55FB0BBF81323D87062DB1F6D1C"
        #expect(LinkParser.parse("\(lower)\n\(upper)\n\(lower)") == [
            .magnet(infoHash: "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c", displayName: nil, original: lower),
            .magnet(infoHash: "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c", displayName: nil, original: upper)
        ])
    }

    @Test("空白、无链接与非法 URL", arguments: [
        "", " \t\r\n\u{2003}", "只有中文说明，没有链接。", "not a link", "file:///tmp/file.zip",
        "https://", "http:///file.zip", "ftp:///file.zip", "https://[::1/file.zip"
    ])
    func emptyResults(_ text: String) {
        #expect(LinkParser.parse(text).isEmpty)
    }
}

/// 中文分享文案里常见的「链接 + 提取码/密码」写法，全角句读之后的内容不能算进链接。
@Suite struct LinkParserShareTextTests {
    @Test("全角句读结束链接", arguments: [
        "https://example.com/a.zip，提取码abcd",
        "下载地址https://example.com/a.zip，密码 123",
        "https://example.com/a.zip。",
        "https://example.com/a.zip；备用：https://example.org/b.zip",
        "地址：https://example.com/a.zip！",
    ])
    func fullWidthSentencePunctuationEndsLink(_ text: String) throws {
        let links = LinkParser.parse(text)
        let first = try #require(links.first)
        guard case .http(let url, _, _) = first else {
            Issue.record("应识别为 HTTP 直链：\(first)")
            return
        }
        #expect(url.absoluteString == "https://example.com/a.zip")
    }

    @Test func fullWidthBracketsStayInsideFileName() throws {
        let links = LinkParser.parse("资料：https://example.com/报告（最终版）.zip，密码 1234")
        let first = try #require(links.first)
        guard case .http(let url, _, _) = first else {
            Issue.record("应识别为 HTTP 直链：\(first)")
            return
        }
        #expect(url.lastPathComponent == "报告（最终版）.zip")
    }
}
