import Foundation
import Testing
@testable import MuleeCore

struct YtDlpNetworkTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MULEE_NETWORK_TESTS"] == "1"
                   && YtDlpIntegrationFixture.available, "设置 MULEE_NETWORK_TESTS=1 才访问真实视频站"))
    func realVideoDownload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("YtDlp-network-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = YtDlpEngine(
            stateDirectory: root.appendingPathComponent("state"),
            binaryURL: YtDlpIntegrationFixture.binary, installer: nil,
            ffmpegURL: YtDlpIntegrationFixture.ffmpeg,
            denoURL: URL(fileURLWithPath: "/opt/homebrew/bin/deno"), updatesEnabled: false
        )
        do {
            try await engine.start(options: EngineOptions(downloadDirectory: root.appendingPathComponent("downloads")))
            // yt-dlp 上游用于验证下载的短测试视频；允许环境变量指定其他已授权视频。
            let address = ProcessInfo.processInfo.environment["MULEE_VIDEO_TEST_URL"] ?? "https://www.youtube.com/watch?v=BaW_jenozKc"
            let url = try #require(URL(string: address))
            let site: VideoSite = url.host?.contains("bilibili") == true ? .bilibili : .youtube
            let id = try await engine.add(link: .video(url: url, site: site, original: address))
            let done = try await YtDlpIntegrationFixture.waitFor(engine, id: id, timeout: .seconds(180)) { $0.status == .completed }
            #expect(done.receivedBytes > 0)
            await engine.stop()
        } catch {
            await engine.stop()
            throw error
        }
    }
}
