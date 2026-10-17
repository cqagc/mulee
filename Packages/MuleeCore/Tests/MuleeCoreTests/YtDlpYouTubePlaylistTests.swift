import Foundation
import Testing
@testable import MuleeCore

struct YtDlpYouTubePlaylistTests {
    @Test(arguments: [
        "https://www.youtube.com/watch?v=Example0001&list=ExampleList&index=2",
        "https://www.youtube.com/playlist?list=ExampleList",
        "https://youtu.be/Example0001?list=ExampleList",
        "https://music.youtube.com/watch?v=Example0001&list=ExampleList"
    ])
    func parserRetainsPlaylistIdentity(_ text: String) throws {
        let link = try #require(LinkParser.parse(text).first)

        #expect(link.kind == .video)
        #expect(link.playlistID == "ExampleList")
        if text.contains("/playlist?") {
            #expect(link.youtubeVideoID == nil)
            #expect(link.singleVideoURL == nil)
        } else {
            #expect(link.youtubeVideoID == "Example0001")
            #expect(link.singleVideoURL?.absoluteString == "https://www.youtube.com/watch?v=Example0001")
        }
    }

    @Test func bareShortHostPlaylistHasNoCurrentVideo() throws {
        let link = try #require(LinkParser.parse("https://youtu.be?list=ExampleList").first)

        #expect(link.playlistID == "ExampleList")
        #expect(link.youtubeVideoID == nil)
        #expect(link.singleVideoURL == nil)
        let unrelated = try #require(LinkParser.parse("https://example.org/watch?v=Example0001&list=ExampleList").first)
        #expect(unrelated.playlistID == nil)
        #expect(unrelated.kind == .http)
    }

    @Test func flatPlaylistUsesSingleVideoURLsAndPreservesOrder() throws {
        let source = try #require(URL(string: "https://www.youtube.com/playlist?list=ExampleList"))
        let data = Data(#"""
        {"title":"示例列表","entries":[
            {"id":"Example0001","ie_key":"Youtube","title":"示例一","duration":65},
            {"id":"Example0002","extractor_key":"Youtube","title":"示例二"},
            {"id":"Example0001","title":"重复项"},
            {"id":"bad&id=other","title":"非法定位"},
            {"title":"缺少视频标识"}
        ]}
        """#.utf8)

        let entries = try YtDlpPlaylist.parse(data, source: source)

        #expect(entries.count == 2)
        #expect(entries.map(\.site) == [.youtube, .youtube])
        #expect(entries.map(\.index) == [1, 2])
        #expect(entries[0].displayTitle == "#1 示例一")
        #expect(entries[0].taskTitle == "#1 示例一")
        #expect(entries[0].duration == 65)
        #expect(entries[0].durationDescription != nil)
        #expect(entries[1].durationDescription == nil)
        #expect(entries[0].playlistTitle == "示例列表")
        #expect(entries[0].videoIdentity == "Youtube:Example0001")
        #expect(entries[1].link == .video(url: entries[1].url, site: .youtube, original: entries[1].url.absoluteString))
        #expect(entries[1].url.absoluteString == "https://www.youtube.com/watch?v=Example0002")
        #expect(YtDlpPlaylistEntry.arguments(for: entries[1].url, site: .youtube) == ["--no-playlist"])
    }

    @Test func malformedAndOversizedYouTubePlaylistsFail() throws {
        let source = try #require(URL(string: "https://www.youtube.com/playlist?list=ExampleList"))
        #expect(throws: (any Error).self) { try YtDlpPlaylist.parse(Data("invalid".utf8), source: source) }
        let tooMany = try JSONSerialization.data(withJSONObject: ["entries": Array(repeating: ["id": "Example0001"], count: 1001)])
        #expect(throws: (any Error).self) { try YtDlpPlaylist.parse(tooMany, source: source) }
        #expect(try YtDlpPlaylist.parse(Data(#"{"entries":[]}"#.utf8), source: source).isEmpty)
        let unavailable = Data(#"{"entries":[null,{"id":"Example0002","title":"示例二","duration":-1}]}"#.utf8)
        let entries = try YtDlpPlaylist.parse(unavailable, source: source)
        #expect(entries.first?.index == 2)
        #expect(entries.first?.duration == nil)
    }

    @Test func metadataKeepsIdentityAndSeparatesCaptionLanguages() throws {
        let data = Data(#"""
        {"extractor_key":"Youtube","id":"Example0001","title":"示例视频","duration":42,"formats":[],
         "subtitles":{"zh-Hans":[{}],"en":[{}],"live_chat":[{}],"danmaku":[{}],"empty":[],"bad,id":[{}]},
         "automatic_captions":{"en":[{}],"ja":[{}],"live_chat":[{}]}}
        """#.utf8)

        let metadata = try YtDlpVideoMetadata.parse(data)

        #expect(metadata.videoIdentity == "Youtube:Example0001")
        #expect(metadata.subtitleLanguages == ["en", "zh-Hans"])
        #expect(metadata.automaticCaptionLanguages == ["en", "ja"])
        #expect(metadata.title == "示例视频")
        #expect(metadata.duration == 42)
        #expect(metadata.formats.isEmpty)
        #expect(try YtDlpVideoMetadata.parse(Data(#"{"formats":[]}"#.utf8)).videoIdentity == nil)
        #expect(throws: (any Error).self) { try YtDlpVideoMetadata.parse(Data("invalid".utf8)) }
    }

    @Test func formatProbeStripsPlaylistAndRejectsPureListBeforeLaunching() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("yt-dlp")
        let script = #"""
        #!/bin/sh
        single=0
        for arg in "$@"; do
            case "$arg" in
                *list=*|*index=*|*start_radio=*) exit 2 ;;
                https://www.youtube.com/watch?v=Example0001) single=1 ;;
            esac
        done
        [ "$single" = 1 ] || exit 3
        printf '%s\n' '{"extractor_key":"Youtube","id":"Example0001","formats":[]}'
        """#
        try Data(script.utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let video = try #require(URL(string: "https://music.youtube.com/watch?v=Example0001&list=ExampleList&index=2&start_radio=1"))

        let metadata = try await YtDlpFormats.fetchMetadata(url: video, site: .youtube, binary: binary)

        #expect(metadata.videoIdentity == "Youtube:Example0001")
        let playlist = try #require(URL(string: "https://www.youtube.com/playlist?list=ExampleList"))
        await #expect(throws: EngineError.unsupportedLink) {
            try await YtDlpFormats.fetchMetadata(url: playlist, site: .youtube, binary: binary)
        }
    }

    @Test func playlistProbeUsesFlatModeAndBoundedList() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("yt-dlp")
        let script = #"""
        #!/bin/sh
        flat=0
        yes=0
        limit=0
        previous=''
        for arg in "$@"; do
            [ "$arg" = '--flat-playlist' ] && flat=1
            [ "$arg" = '--yes-playlist' ] && yes=1
            [ "$previous" = '--playlist-end' ] && [ "$arg" = '1000' ] && limit=1
            previous="$arg"
        done
        [ "$flat$yes$limit" = '111' ] || exit 2
        [ "$previous" = 'https://www.youtube.com/playlist?list=ExampleList' ] || exit 3
        printf '%s\n' '{"title":"示例列表","entries":[{"id":"Example0001","ie_key":"Youtube","title":"示例一"}]}'
        """#
        try Data(script.utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let source = try #require(URL(string: "https://youtu.be/Example0001?list=ExampleList&index=2"))

        let entries = try await YtDlpPlaylist.fetch(url: source, binary: binary)

        #expect(entries.first?.videoIdentity == "Youtube:Example0001")
    }
}
