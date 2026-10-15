import Foundation
import Testing
@testable import MuleeCore

struct BilibiliSeasonMetadataTests {
    private static let seasonURL = URL(string: "https://www.bilibili.com/bangumi/play/ss900000001?from_spmid=fixture")!
    private static let season = """
    {"code":0,"result":{"title":"雾港奇谭","episodes":[
        {"ep_id":900000011,"title":"1","long_title":"雾中的来客"},
        {"id":900000012,"title":"2","long_title":""},
        {"ep_id":900000013,"title":"SP","long_title":"灯塔番外"},
        {"ep_id":900000014,"title":"PV1"}
    ]}}
    """

    private static func response(_ request: URLRequest, body: String, status: Int = 200) throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
        return (Data(body.utf8), response)
    }

    @Test(arguments: [
        ("https://www.bilibili.com/bangumi/play/ss900000001?from_spmid=fixture", "season_id", "900000001"),
        ("https://www.bilibili.com/bangumi/play/ep900000012/", "ep_id", "900000012")
    ])
    func seasonAndEpisodeLinksUsePublicAPI(source: String, key: String, value: String) async throws {
        let source = try #require(URL(string: source))
        let metadata = await YtDlpPlaylist.fetchMetadata(url: source) { request in
            let url = try #require(request.url)
            #expect(url.host == "api.bilibili.com")
            #expect(url.path == "/pgc/view/web/season")
            #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: key, value: value)])
            #expect(request.timeoutInterval == 10)
            #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("Mozilla/5.0") == true)
            #expect(request.value(forHTTPHeaderField: "Referer") == "https://www.bilibili.com/")
            return try Self.response(request, body: Self.season)
        }
        let entries = try #require(metadata)
        // 集数标签随系统语言本地化，期望值走同一个字符串目录。
        let episode = { (number: String) in String(localized: "第 \(number) 话", bundle: .module) }
        #expect(entries.map(\.title) == [episode("1") + " · 雾中的来客", episode("2"), "SP · 灯塔番外", "PV1"])
        #expect(entries.map(\.index) == [1, 2, 3, 4])
        #expect(entries.map { $0.url.absoluteString } == (11...14).map { "https://www.bilibili.com/bangumi/play/ep9000000\($0)" })
        #expect(entries.allSatisfy { YtDlpPlaylistEntry.arguments(for: $0.url, site: .bilibili) == ["--no-playlist", "--playlist-items", "1"] })
    }

    @Test func cookiesRespectAPIHostPathAndExpiry() async throws {
        func cookie(
            _ name: String, domain: String = ".bilibili.com", path: String = "/",
            hostOnly: Bool = false, expiration: Double? = nil
        ) -> VideoCookie {
            VideoCookie(domain: domain, path: path, name: name, value: "synthetic", secure: true,
                        httpOnly: true, hostOnly: hostOnly, expirationDate: expiration)
        }
        let cookies = [
            cookie("SESSDATA"), cookie("api", domain: "api.bilibili.com", hostOnly: true),
            cookie("www", domain: "www.bilibili.com", hostOnly: true),
            cookie("foreign", domain: ".youtube.com"), cookie("expired", expiration: 1),
            cookie("path", path: "/video"), cookie("boundary", path: "/pgc/view/web/sea")
        ]
        let entries = await YtDlpPlaylist.fetchMetadata(url: Self.seasonURL, cookies: cookies) { request in
            #expect(request.value(forHTTPHeaderField: "Cookie") == "SESSDATA=synthetic; api=synthetic")
            return try Self.response(request, body: Self.season)
        }
        #expect(entries?.count == 4)
    }

    @Test func multipartBVUsesPagesWithoutFlatPlaylist() async throws {
        let source = try #require(URL(string: "https://www.bilibili.com/video/BV0000000000?p=2"))
        let metadata = await YtDlpPlaylist.fetchMetadata(url: source) { request in
            #expect(request.url?.path == "/x/web-interface/view")
            #expect(request.url?.query == "bvid=BV0000000000")
            return try Self.response(request, body: """
            {"code":0,"data":{"pages":[{"page":1,"part":"雾港序章"},{"page":2,"part":"灯塔之谜"}]}}
            """)
        }
        let entries = try #require(metadata)
        #expect(entries.map(\.title) == ["雾港序章", "灯塔之谜"])
        #expect(entries.map { $0.url.query } == ["p=1", "p=2"])
        #expect(entries.map(\.index) == [1, 2])
    }

    @Test func singleBVAndUGCCollectionsKeepExistingSemantics() async throws {
        let source = try #require(URL(string: "https://www.bilibili.com/video/BV0000000000"))
        let single = await YtDlpPlaylist.fetchMetadata(url: source) { request in
            try Self.response(request, body: #"{"code":0,"data":{"pages":[{"page":1,"part":"雾港序章"}]}}"#)
        }
        #expect(single == [])
        let metadata = await YtDlpPlaylist.fetchMetadata(url: source) { request in
            try Self.response(request, body: """
            {"code":0,"data":{"pages":[{"page":1}],"ugc_season":{"sections":[{"episodes":[
                {"bvid":"BV0000000001","title":"雾港序章"},{"bvid":"BV0000000002","title":"灯塔之谜"}
            ]}]}}}
            """)
        }
        let collection = try #require(metadata)
        #expect(collection.map(\.title) == ["雾港序章", "灯塔之谜"])
        #expect(collection[1].url.absoluteString == "https://www.bilibili.com/video/BV0000000002?p=1")
    }

    @Test(arguments: [
        "invalid", "{}", #"{"code":-404,"result":{"episodes":[]}}"#,
        #"{"code":0,"result":{"episodes":[]}}"#,
        #"{"code":0,"result":{"episodes":[{"title":"1"}]}}"#,
        #"{"code":0,"result":{"episodes":[{"ep_id":0,"title":"1"}]}}"#,
        #"{"code":0,"result":{"episodes":[{"ep_id":900000011,"title":"1"},{"ep_id":900000011,"title":"2"}]}}"#
    ])
    func invalidSeasonResponsesAllowFallback(body: String) async {
        let entries = await YtDlpPlaylist.fetchMetadata(url: Self.seasonURL) { request in
            try Self.response(request, body: body)
        }
        #expect(entries == nil)
    }

    @Test func transportAndHTTPFailuresAllowFallback() async {
        let unavailable = await YtDlpPlaylist.fetchMetadata(url: Self.seasonURL) { request in
            try Self.response(request, body: Self.season, status: 503)
        }
        #expect(unavailable == nil)
        let timeout = await YtDlpPlaylist.fetchMetadata(url: Self.seasonURL) { _ in
            throw URLError(.timedOut)
        }
        #expect(timeout == nil)
    }

    @Test func oversizedResponsesAllowFallback() async throws {
        let body = try JSONSerialization.data(withJSONObject: ["code": 0, "result": [
            "episodes": Array(repeating: ["ep_id": 900000011, "title": "1"], count: 1_001)
        ]])
        let entries = await YtDlpPlaylist.fetchMetadata(url: Self.seasonURL) { request in
            try Self.response(request, body: String(decoding: body, as: UTF8.self))
        }
        #expect(entries == nil)
        let oversized = await YtDlpPlaylist.fetchMetadata(url: Self.seasonURL) { request in
            let response = try Self.response(request, body: "{}").1
            return (Data(repeating: 32, count: 4_194_305), response)
        }
        #expect(oversized == nil)
    }

    @Test(arguments: [
        "https://bilibili.com.evil.invalid/bangumi/play/ss900000001",
        "https://www.bilibili.com/bangumi/play/ssinvalid", "file:///bangumi/play/ss900000001",
        "https://user:password" + "@www.bilibili.com/bangumi/play/ss900000001",
        "https://www.bilibili.com/other/BV0000000000", "https://b23.tv/fixture"
    ])
    func unsupportedLinksDoNotIssueRequests(source: String) async throws {
        let url = try #require(URL(string: source))
        let entries = await YtDlpPlaylist.fetchMetadata(url: url) { _ in
            Issue.record("不支持的链接不应发出网络请求")
            throw URLError(.badURL)
        }
        #expect(entries == nil)
    }

    @Test func cancellationDoesNotReturnMetadata() async throws {
        let task = Task {
            await YtDlpPlaylist.fetchMetadata(url: Self.seasonURL) { request in
                withUnsafeCurrentTask { $0?.cancel() }
                return try Self.response(request, body: Self.season)
            }
        }
        #expect(await task.value == nil)
    }
}
