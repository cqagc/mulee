import Foundation
import Testing
@testable import MuleeCore

struct YtDlpPlaylistTests {
    @Test func multipartURLsKeepPartAndTitle() throws {
        let source = try #require(URL(string: "https://www.bilibili.com/video/BVexample/?p=2"))
        let data = Data(#"{"entries":[{"url":"https://www.bilibili.com/video/BVexample?p=1","title":"示例第一部分"},{"url":"https://www.bilibili.com/video/BVexample?p=2","title":"示例第二部分"}]}"#.utf8)
        let entries = try YtDlpPlaylist.parse(data, source: source)
        #expect(entries.count == 2)
        #expect(entries[1].index == 2)
        #expect(entries[1].title == "示例第二部分")
        #expect(YtDlpPlaylistEntry.selectedPart(in: entries[1].url) == 2)
        #expect(YtDlpPlaylistEntry.arguments(for: entries[1].url, site: .bilibili) == ["--no-playlist", "--playlist-items", "2"])
    }

    @Test func collectionsKeepDistinctVideosAndRejectForeignURLs() throws {
        let source = try #require(URL(string: "https://www.bilibili.com/list/example"))
        let data = Data(#"{"entries":[{"url":"https://www.bilibili.com/video/BVfirst","title":"示例一"},{"url":"https://www.bilibili.com/video/BVsecond","title":"示例二"},{"url":"https://evil.org/video"}]}"#.utf8)
        let entries = try YtDlpPlaylist.parse(data, source: source)
        #expect(entries.count == 2)
        #expect(entries[1].url.path == "/video/BVsecond")
        #expect(entries[1].url.query == nil)
    }

    @Test func invalidJSONAndOversizedListsAreRejected() throws {
        let source = try #require(URL(string: "https://www.bilibili.com/video/BVexample"))
        #expect(throws: (any Error).self) { try YtDlpPlaylist.parse(Data("invalid".utf8), source: source) }
        let data = try JSONSerialization.data(withJSONObject: ["entries": Array(repeating: ["title": "sample"], count: 1_001)])
        #expect(throws: (any Error).self) { try YtDlpPlaylist.parse(data, source: source) }
    }

    @Test func publicMetadataAddsPartTitlesAndCollectionEntries() throws {
        let source = try #require(URL(string: "https://www.bilibili.com/video/BVexample?p=2"))
        let entry = YtDlpPlaylistEntry(index: 2, title: "", url: source)
        let parts = YtDlpBilibiliMetadata.enrich([entry, entry], video: ["pages": [["page": 2, "part": "示例第二部分"]]], source: source)
        #expect(parts.first?.title == "示例第二部分")
        let season: [String: Any] = ["ugc_season": ["sections": [["episodes": [
            ["bvid": "BVfirst", "title": "示例一"], ["bvid": "BVsecond", "title": "示例二"]
        ]]]]]
        let collection = YtDlpBilibiliMetadata.enrich([], video: season, source: source)
        #expect(collection.count == 2)
        #expect(collection[1].url.path == "/video/BVsecond")
    }

    @Test func metadataTimeoutTerminatesTheProcess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("yt-dlp")
        try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let url = try #require(URL(string: "https://www.bilibili.com/video/BVexample"))
        await #expect(throws: (any Error).self) {
            try await YtDlpPlaylist.fetch(url: url, binary: binary, timeout: .milliseconds(50))
        }
    }
}
