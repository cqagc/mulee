import Foundation
import Testing
@testable import MuleeCore

@Suite struct YtDlpFormatsTests {
    @Test func metadataListsResolutionCodecSizeAndLogin() throws {
        let data = Data(#"""
        {"availability":"needs_auth","formats":[
            {"format_id":"video-1080","height":1080,"vcodec":"avc1","acodec":"none","filesize":1234},
            {"format_id":"audio","vcodec":"none","acodec":"aac","filesize_approx":100},
            {"format_id":"combined","height":720,"vcodec":"vp9","acodec":"opus"},
            {"format_id":"drm","vcodec":"avc1","has_drm":true},
            {"format_id":"bad+selector","vcodec":"avc1"},
            {"format_id":"audio","vcodec":"none","acodec":"aac"},
            {"format_id":"empty","vcodec":"none","acodec":"none"}
        ]}
        """#.utf8)
        let formats = try YtDlpFormats.parse(data)
        #expect(formats.map(\.id) == ["video-1080", "audio", "combined"])
        #expect(formats.first?.resolution == "1080p")
        #expect(formats.first?.codec == "avc1")
        #expect(formats.first?.size == 1234)
        #expect(formats.first?.selector == "video-1080+ba/video-1080")
        #expect(formats[1].size == 100)
        #expect(formats[1].selector == "audio")
        #expect(formats.allSatisfy { $0.needsLogin })
        #expect(formats[2].size == nil)
    }

    @Test func malformedMetadataFailsWithoutLeakingOutput() {
        for text in ["not json", "{}", "[]", #"{"formats":null}"#] {
            #expect(throws: YtDlpFormats.ListingError.self) { try YtDlpFormats.parse(Data(text.utf8)) }
        }
        #expect(throws: YtDlpFormats.ListingError.self) { try YtDlpFormats.parse(Data(repeating: 0, count: 8_388_609)) }
    }

    @Test func selectorsAreLimitedToSingleIDs() {
        for id in ["", "a+b", "best/other", "a,b", "--exec x", String(repeating: "a", count: 129), "字幕"] {
            #expect(!YtDlpFormat.isValidID(id))
        }
        #expect(YtDlpFormat.isValidID("format_720.1-vp9"))
    }

    @Test func listingTimeoutTerminatesTheProcess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("yt-dlp")
        try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let url = try #require(URL(string: "https://www.youtube.com/watch?v=example"))
        await #expect(throws: YtDlpFormats.ListingError.timeout) {
            try await YtDlpFormats.fetch(url: url, site: .youtube, binary: binary, timeout: .milliseconds(50))
        }
    }

    @Test func listingUsesJSONAndNeverDownloads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("yt-dlp")
        let script = #"""
        #!/bin/sh
        json=0
        skip=0
        for arg in "$@"; do
            [ "$arg" = "-J" ] && json=1
            [ "$arg" = "--skip-download" ] && skip=1
        done
        [ "$json" = 1 ] && [ "$skip" = 1 ] || exit 2
        printf '%s\n' '{"formats":[{"format_id":"720","vcodec":"avc1","acodec":"aac"}]}'
        """#
        try Data(script.utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let url = try #require(URL(string: "https://www.youtube.com/watch?v=example"))
        let formats = try await YtDlpFormats.fetch(url: url, site: .youtube, binary: binary)
        #expect(formats.map(\.id) == ["720"])
    }

}
