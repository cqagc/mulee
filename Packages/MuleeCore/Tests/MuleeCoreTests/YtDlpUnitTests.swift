import Foundation
import Testing
@testable import MuleeCore

struct YtDlpUnitTests {
    @Test func separateAudioVideoProgress() {
        var progress = YtDlpProgress()
        #expect(progress.consume(#"MULEE:{"event":"metadata","title":"测试视频","formats":[{"format_id":"v","filesize":1000},{"format_id":"a","filesize":200}]}"#) == true)
        #expect(progress.title == "测试视频")
        #expect(progress.totalBytes == 1200)
        #expect(progress.consume(#"MULEE:{"event":"progress","format":"v","downloaded":1000,"total":1000,"speed":500,"eta":2}"#) == true)
        #expect(progress.consume(#"MULEE:{"event":"progress","format":"a","downloaded":50,"total":200,"speed":100,"eta":1.5}"#) == true)
        #expect(progress.receivedBytes == 1050)
        #expect(progress.totalBytes == 1200)
        #expect(progress.rate == 100)
        #expect(progress.eta == 1.5)
        #expect(progress.consume(#"MULEE:{"event":"postprocess"}"#) == true)
        #expect(progress.postProcessing)
        #expect(progress.rate == 0)
        #expect(progress.consume(#"MULEE:{"event":"file","path":"/tmp/example.mp4"}"#) == true)
        #expect(progress.finalPath == "/tmp/example.mp4")
    }

    @Test func unknownSizeAndMalformedJSON() {
        var progress = YtDlpProgress()
        #expect(progress.consume("not JSON") == false)
        #expect(progress.consume("MULEE:{bad}") == false)
        #expect(progress.consume(#"MULEE:{"event":"progress","format":"v","downloaded":250,"total":null,"speed":"NA","eta":null}"#) == true)
        #expect(progress.receivedBytes == 250)
        #expect(progress.totalBytes == nil)
        #expect(progress.rate == 0)
        #expect(progress.eta == nil)
    }

    @Test func singleFormatEstimateAndAlreadyDownloadedStream() {
        var progress = YtDlpProgress()
        _ = progress.consume(#"MULEE:{"event":"metadata","format":"18","total":1000}"#)
        _ = progress.consume(#"MULEE:{"event":"progress","format":"18","downloaded":500,"total":1000}"#)
        #expect(progress.totalBytes == 1000)
        #expect(progress.receivedBytes == 500)
        _ = progress.consume(#"MULEE:{"event":"progress","status":"finished","format":"18","total":1000}"#)
        #expect(progress.receivedBytes == 1000)
        var separate = YtDlpProgress()
        _ = separate.consume(#"MULEE:{"event":"metadata","formats":[{"format_id":"v","filesize":null,"filesize_approx":1000},{"format_id":"a","filesize":200}]}"#)
        #expect(separate.totalBytes == 1200)
    }

    @Test func qualityAndSubtitleArguments() {
        #expect(YtDlpQuality.compatible.arguments.contains("mp4"))
        let selector = YtDlpQuality.compatible.arguments[1]
        #expect(selector.contains("avc1"))
        #expect(selector.contains("hvc1"))
        #expect(selector.contains("mp4a"))
        #expect(selector.contains("[acodec~=?"))
        #expect(YtDlpQuality.best.arguments == ["--format", "bv*+ba/b", "--merge-output-format", "mkv", "--remux-video", "mkv"])
        #expect(YtDlpSubtitles().arguments.isEmpty)
        #expect(YtDlpSubtitles(danmaku: true).arguments.contains("danmaku"))
        #expect(YtDlpSubtitles(closedCaptions: true).arguments.contains("all,-danmaku"))
    }

    @Test(arguments: [
        ("ERROR: Sign in to confirm your age", "此视频需要登录，请提供有效的 cookies 文件。"),
        ("ERROR: not available in your country", "此视频受地区限制。"),
        ("ERROR: video has been deleted", "视频不存在或已删除。"),
        ("ERROR: connection timed out", "网络连接失败，请检查网络与代理。"),
        ("ERROR: Unable to extract player response", "视频网站规则已变化，需要更新 yt-dlp。"),
        ("ERROR: ffmpeg is not installed", "缺少可用的 ffmpeg，无法合并音视频。")
    ])
    func readableErrors(raw: String, expected: String) {
        let message = YtDlpErrorDescriptions.message(raw)
        #expect(message.contains(String(localized: String.LocalizationValue(expected), bundle: .module)))
        #expect(message.hasSuffix(raw))
    }

    @Test func restrictedEnvironment() {
        let environment = YtDlpProcess.environment
        #expect(environment["LANG"] == "en_US.UTF-8")
        #expect(environment["LC_ALL"] == "en_US.UTF-8")
        #expect(environment["PYTHONPATH"] == nil)
        #expect(environment["OPENAI_API_KEY"] == nil)
        #expect(environment["https_proxy"] == ProcessInfo.processInfo.environment["https_proxy"])
    }

    @Test func fileSafetyRejectsTraversalAndSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("YtDlp-safety-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let job = YtDlpJob(id: id, url: root, site: .other, directory: root, name: "示例")
        #expect(YtDlpFileSafety.belongs(root.appendingPathComponent(id + "-test.mp4.part"), to: job))
        #expect(!YtDlpFileSafety.belongs(root.appendingPathComponent("../" + id + "-test.mp4"), to: job))
        #expect(!YtDlpFileSafety.belongs(root.appendingPathComponent("someone-else.mp4"), to: job))
        let symlink = root.appendingPathComponent(id + "-link.mp4")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        #expect(!YtDlpFileSafety.belongs(symlink, to: job))
    }
}
