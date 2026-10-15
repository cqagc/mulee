import Foundation
import Testing
@testable import MuleeCore

struct YtDlpDanmakuTests {
    @Test(arguments: [
        #"MULEE:{"event":"metadata","width":1280,"height":720}"#,
        #"MULEE:{"event":"metadata","width":null,"height":null,"formats":[{"vcodec":"h264","width":1280,"height":720},{"vcodec":"none"}]}"#
    ])
    func extractsResolutionFromMetadataOrVideoFormat(line: String) {
        var progress = YtDlpProgress()

        #expect(progress.consume(line) == true)

        #expect(progress.videoSize == CGSize(width: 1280, height: 720))
        #expect(YtDlpProgress.metadataTemplate.contains("%(width)j"))
        #expect(YtDlpProgress.metadataTemplate.contains("%(height)j"))
    }

    @Test func unavailableResolutionUsesDefault() {
        var progress = YtDlpProgress()
        _ = progress.consume(#"MULEE:{"event":"metadata","width":0,"height":720}"#)

        #expect(progress.videoSize == nil)
        #expect(DanmakuASSWriter(videoSize: progress.videoSize).header.contains("PlayResY: 1080"))
    }

    @Test(arguments: [0, 1, 2, 3, 4])
    func convertsOnlyEnabledBilibiliAndKeepsXMLOnFailure(scenario: Int) async throws {
        let fixture = try DanmakuTestFixture()
        defer { fixture.cleanup() }
        let binary = fixture.root.appendingPathComponent("yt-dlp")
        let xml = scenario == 1 ? "<i><d>损坏" : "<i><d p=\"0,1,25,16777215\">转换测试</d></i>"
        let script = Self.script(xml: xml, codec: "h264", outputXML: scenario != 4)
        try Data(script.utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let engine = YtDlpEngine(
            stateDirectory: fixture.root.appendingPathComponent("state"), binaryURL: binary, installer: nil,
            subtitles: YtDlpSubtitles(danmaku: scenario != 2), updatesEnabled: false
        )
        do {
            try await engine.start(options: EngineOptions(downloadDirectory: fixture.root))
            let url = try #require(URL(string: "https://example.invalid/danmaku"))
            let id = try await engine.add(link: .video(
                url: url, site: scenario == 3 ? .other : .bilibili, original: url.absoluteString
            ))

            let done = try await YtDlpIntegrationFixture.waitFor(engine, id: id) { $0.status == .completed }
            let video = try #require(done.savePath)
            let base = video.deletingPathExtension()
            let ass = base.appendingPathExtension("danmaku.ass")
            let source = base.appendingPathExtension("danmaku.xml")

            #expect(done.errorMessage == nil)
            #expect(FileManager.default.fileExists(atPath: source.path) == (scenario != 0 && scenario != 4))
            #expect(FileManager.default.fileExists(atPath: ass.path) == (scenario == 0))
            if scenario == 0 {
                let output = try String(contentsOf: ass, encoding: .utf8)
                #expect(output.contains("转换测试"))
                #expect(output.contains("PlayResX: 1280"))
                #expect(output.contains("PlayResY: 720"))
            }
            await engine.stop()
        } catch {
            await engine.stop()
            throw error
        }
    }

    @Test func conversionRunsAfterHEVCPostprocessing() async throws {
        let fixture = try DanmakuTestFixture()
        defer { fixture.cleanup() }
        let binary = fixture.root.appendingPathComponent("yt-dlp")
        let ffmpeg = fixture.root.appendingPathComponent("ffmpeg")
        try Data(Self.script(
            xml: "<i><d p=\"0,1,25,0\">尚未后处理</d></i>", codec: "hevc"
        ).utf8).write(to: binary)
        try Data("""
        #!/bin/sh
        while [ "$#" -gt 0 ]; do
            case "$1" in
                -i) video="$2"; shift 2 ;;
                *) output="$1"; shift ;;
            esac
        done
        printf '%s' '<i><d p="0,1,25,0">后处理完成</d></i>' > "${video%.*}.danmaku.xml"
        printf '%s' 'remuxed' > "$output"
        """.utf8).write(to: ffmpeg)
        for executable in [binary, ffmpeg] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        let engine = YtDlpEngine(
            stateDirectory: fixture.root.appendingPathComponent("state"), binaryURL: binary, installer: nil,
            ffmpegURL: ffmpeg, subtitles: YtDlpSubtitles(danmaku: true), updatesEnabled: false
        )
        do {
            try await engine.start(options: EngineOptions(downloadDirectory: fixture.root))
            let url = try #require(URL(string: "https://example.invalid/danmaku"))
            let id = try await engine.add(link: .video(url: url, site: .bilibili, original: url.absoluteString))

            let done = try await YtDlpIntegrationFixture.waitFor(engine, id: id) { $0.status == .completed }
            let video = try #require(done.savePath)
            let ass = video.deletingPathExtension().appendingPathExtension("danmaku.ass")
            let content = try String(contentsOf: ass, encoding: .utf8)

            #expect(try String(contentsOf: video, encoding: .utf8) == "remuxed")
            #expect(content.contains("后处理完成"))
            #expect(!content.contains("尚未后处理"))
            await engine.stop()
        } catch {
            await engine.stop()
            throw error
        }
    }

    private static func script(xml: String, codec: String, outputXML: Bool = true) -> String {
        """
        #!/bin/sh
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --paths) directory="$2"; shift 2 ;;
                --output) template="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        prefix="${template%%\\%*}"
        file="$directory/${prefix}fixture.mp4"
        /usr/bin/touch "$file"
        \(outputXML ? "printf '%s' '" + xml + "' > \"${file%.*}.danmaku.xml\"" : ":")
        printf '%s\\n' 'MULEE:{"event":"metadata","vcodec":"\(codec)","width":1280,"height":720}'
        printf 'MULEE:{"event":"file","path":"%s"}\\n' "$file"
        """
    }
}
