import Foundation
import Testing
@testable import MuleeCore

@Suite struct SmartPasteParserTests {
    @Test func torrentFilesHaveTheirOwnRecognitionMessage() throws {
        let rows = SmartPasteParser.parse("file:///tmp/sample.torrent")
        #expect(rows.first?.links.count == 1)
        #expect(rows.first?.message == "已识别种子文件（1 个）")
        #expect(SmartPasteParser.parse("https://example.com/sample.zip").first?.message == "已识别下载链接（1 个）")
    }

    @Test func curlHeadersQuotesAndContinuation() throws {
        let command = """
        curl --compressed \\
          'https://example.com/file.zip' \\
          -H 'Accept: application/zip' -H "X-Note: two words" \\
          -b 'session=sample' -A 'Example Browser' -e https://example.com/page
        """
        let result = try CurlCommandParser.parse(command)
        #expect(result.urls == ["https://example.com/file.zip"])
        #expect(result.context.headers["Accept"] == "application/zip")
        #expect(result.context.headers["X-Note"] == "two words")
        #expect(result.context.cookie == "session=sample")
        #expect(result.context.userAgent == "Example Browser")
        #expect(result.context.referer?.path == "/page")
        let rows = SmartPasteParser.parse(command)
        #expect(rows.count == 1)
        #expect(rows.first?.links.count == 1)
        #expect(rows.first?.context.cookie == "session=sample")
        let windowsRows = SmartPasteParser.parse(command.replacingOccurrences(of: "\n", with: "\r\n"))
        #expect(windowsRows.count == 1)
        #expect(windowsRows.first?.context.cookie == "session=sample")
    }

    @Test func attachedAndLongOptions() throws {
        let result = try CurlCommandParser.parse(
            "curl --url=https://example.com/file -H'Cookie: session=sample' -AExample -ehttps://example.com/ -bother=value --unknown=value -L"
        )
        #expect(result.context.cookie == "other=value")
        #expect(result.context.userAgent == "Example")
        #expect(result.unknownOptions == ["--unknown"])
        #expect(result.context.headers["Cookie"] == nil)
        let browserHeaders = try CurlCommandParser.parse("curl https://example.com/file -H 'Referer: https://example.com/page' -H 'User-Agent: Example Browser'")
        #expect(browserHeaders.context.referer?.path == "/page")
        #expect(browserHeaders.context.userAgent == "Example Browser")
        let encoded = String(decoding: try JSONEncoder().encode(result.context), as: UTF8.self)
        #expect(!encoded.contains("other=value"))
        #expect(!encoded.contains("session=sample"))
    }

    @Test("整条拒绝 shell 语法，不回退提取地址", arguments: [
        "$(id)", "`id`", "; id", "| cat", "&& id", "> file", "< file", "\u{0}"
    ])
    func unsafeCurl(_ suffix: String) {
        let text = "curl https://example.com/file " + suffix
        #expect(throws: CurlCommandParser.ParseError.self) { try CurlCommandParser.parse(text) }
        #expect(SmartPasteParser.parse(text).flatMap(\.links).isEmpty)
    }

    @Test("损坏请求与文件引用拒绝解析", arguments: [
        "curl 'https://example.com/file", "curl https://example.com/file -H", "curl https://example.com/file \\",
        "curl https://example.com/file -b cookies.txt", "curl https://example.com/file -H @headers.txt",
        "curl --url file:///tmp/sample.torrent", "curl https://example.com/file -H 'X-Test: a\nb'",
        "curl https://example.com/file -e ftp://example.com/",
        "curl https://" + "user:password" + "@example.com/file",
        "curl https://example.com/file -H 'Referer: https://" + "user:password" + "@example.com/'"
    ])
    func malformedCurl(_ text: String) {
        #expect(throws: CurlCommandParser.ParseError.self) { try CurlCommandParser.parse(text) }
    }

    @Test func unknownOptionDoesNotExposeAttachedSecret() throws {
        let result = try CurlCommandParser.parse("curl https://example.com/file -usecret")
        #expect(result.unknownOptions == ["-u"])
    }

    @Test func unknownOptionURLIsNeverADownload() throws {
        let result = try CurlCommandParser.parse("curl https://good.example/file -b 'sid=secret' --data 'https://evil.example/'")
        #expect(result.urls == ["https://good.example/file"])
        #expect(SmartPasteParser.parse("curl https://good.example/file --output https://evil.example/").flatMap(\.links).count == 1)
    }

    @Test func mixedHostsDoNotShareCredentials() {
        let rows = SmartPasteParser.parse("curl https://good.example/one --url https://evil.example/two --url https://GOOD.example/three -b sid=secret -H 'Authorization: Bearer test'")
        let entries = rows.flatMap { row in row.links.map { ($0.original, row.context, row.message) } }
        #expect(entries.count == 3)
        for (url, context, message) in entries {
            if URL(string: url)?.host?.lowercased() == "evil.example" {
                #expect(context.requestCookie == nil)
                #expect(context.headers["Authorization"] == nil)
                #expect(message.contains("登录凭据"))
            } else {
                #expect(context.requestCookie == "sid=secret")
                #expect(context.headers["Authorization"] == "Bearer test")
            }
        }
    }

    @Test func totalExpansionLimitAcrossRows() {
        let rows = SmartPasteParser.parse("https://example.com/[1-1000].bin\nhttps://example.com/[1-1000].bin")
        #expect(rows.flatMap(\.links).isEmpty)
        #expect(rows.last?.message.contains("1000") == true)
    }

    @Test func totalExpansionStopsBeforeAllocatingAllURLs() {
        let text = Array(repeating: "https://example.com/[1-1000].bin", count: 10_000).joined(separator: "\n")
        let start = ContinuousClock.now
        let rows = SmartPasteParser.parse(text)
        #expect(start.duration(to: .now) < .seconds(1))
        #expect(rows.flatMap(\.links).isEmpty)
        #expect(rows.last?.message.contains("1000") == true)
        let curl = "curl " + Array(repeating: "https://example.com/[1-1000].bin", count: 10_000).joined(separator: " ")
        let curlStart = ContinuousClock.now
        #expect(SmartPasteParser.parse(curl).flatMap(\.links).isEmpty)
        #expect(curlStart.duration(to: .now) < .seconds(1))
    }

    @Test func wildcardPaddingProductAndBoundaries() throws {
        #expect(try BatchURLExpander.expand("https://example.com/[01-03].zip") == [
            "https://example.com/01.zip", "https://example.com/02.zip", "https://example.com/03.zip"
        ])
        #expect(try BatchURLExpander.expand("[a-b]/[1-2]") == ["a/1", "a/2", "b/1", "b/2"])
        #expect(try BatchURLExpander.expand("[1-1000]").count == 1000)
        #expect(try BatchURLExpander.expand("[9223372036854775807-9223372036854775807]") == ["9223372036854775807"])
        #expect(try BatchURLExpander.expand("http://[::1]/file") == ["http://[::1]/file"])
        for text in ["[1-1001]", "[1-100]/[1-11]", "[9-1]", "[z-a]", "[a-Z]", "[99999999999999999999-99999999999999999999]"] {
            #expect(throws: BatchURLExpander.ExpansionError.self) { try BatchURLExpander.expand(text) }
        }
    }

    @Test func allHashShapesBecomeUsableMagnets() throws {
        for (hash, length) in [(String(repeating: "A", count: 40), 40), (String(repeating: "f", count: 64), 64),
                               (String(repeating: "A", count: 32), 40), (String(repeating: "a", count: 32), 40)] {
            let magnet = try #require(InfoHashLink.magnet(for: hash))
            let link = try #require(LinkParser.parse(magnet).first)
            guard case .magnet(let parsedHash, _, _) = link else { Issue.record("应为磁力链接"); return }
            #expect(parsedHash.count == length)
            #expect(parsedHash == parsedHash.lowercased())
            #expect(SmartPasteParser.parse(hash).first?.links.count == 1)
            #expect(SmartPasteParser.parse(hash).first?.isInfoHash == true)
        }
        for hash in ["", String(repeating: "G", count: 40), String(repeating: "0", count: 32), String(repeating: "a", count: 63)] {
            #expect(InfoHashLink.magnet(for: hash) == nil)
        }
    }

    @Test func mixedRowsKeepErrorsAndLineNumbers() {
        #expect(SmartPasteParser.parse("https://example.com/file.zip").first?.isInfoHash == false)
        let rows = SmartPasteParser.parse("https://example.com/[1-3].zip\n\n无效输入\ncurl https://example.com/file | cat")
        #expect(rows.map(\.line) == [1, 3, 4])
        #expect(rows.map { $0.links.count } == [3, 0, 0])
        #expect(rows.allSatisfy { !$0.message.isEmpty })
    }

    @Test func duplicateHTTPPoliciesMapToAria2() throws {
        var context = DownloadRequestContext()
        context.duplicateAction = .rename
        let rename = try Aria2RequestOptions.values(context: context, checksum: nil)
        #expect(rename["auto-file-renaming"] == .string("true"))
        #expect(rename["allow-overwrite"] == .string("false"))
        context.duplicateAction = .overwrite
        let overwrite = try Aria2RequestOptions.values(context: context, checksum: nil)
        #expect(overwrite["auto-file-renaming"] == .string("false"))
        #expect(overwrite["allow-overwrite"] == .string("true"))
        context.duplicateAction = .ask
        let unresolved = try Aria2RequestOptions.values(context: context, checksum: nil)
        #expect(unresolved["auto-file-renaming"] == nil)
    }

    @Test func torrentMetadataKeepsDistinctTrackers() throws {
        let tracker = "https://tracker.example.com/announce"
        let encoded = "\(tracker.utf8.count):" + tracker
        let data = Data(("d8:announce" + encoded + "13:announce-listll" + encoded
            + "ee4:infod6:lengthi1e4:name6:sampleee").utf8)
        let info = try TorrentFileInfo.parse(data: data)
        #expect(info.trackers == [tracker])
        #expect(info.infoHash.count == 40)
    }

}
