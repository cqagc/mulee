import CryptoKit
import Foundation
import MuleeCore
import Testing
@testable import Mulee

@Suite @MainActor struct VideoEngineTests {
    @Test func videoLinksRouteToVideoEngineAndKeepDetailsAcrossSnapshots() async throws {
        let model = AppModel(tasks: [])
        let http = FakeEngine()
        let video = FakeEngine(kind: .video)
        let coordinator = DownloadCoordinator(model: model, engines: [http, video])
        let configuration = VideoEngineConfiguration(quality: .best, danmaku: false)
        await coordinator.start(
            options: EngineOptions(downloadDirectory: URL(filePath: "/tmp/Mulee")),
            videoConfiguration: configuration
        )
        let links = LinkParser.parse("https://www.bilibili.com/video/BV1xx411c7XX\nhttps://www.youtube.com/watch?v=fixture")

        await coordinator.add(links: links, autoExtract: false)
        await video.setSnapshots([
            EngineTaskSnapshot(
                engineTaskID: "task-1", name: "示例视频.mp4", totalBytes: 100,
                receivedBytes: 100, downloadRate: 0, uploadRate: 0, status: .completed,
                connections: 0, savePath: nil, sourceURL: nil, errorMessage: nil
            )
        ])
        await coordinator.poll()

        #expect(await video.addedLinks == links)
        #expect(await http.addedLinks.isEmpty)
        let first = try #require(model.tasks.first)
        #expect(first.detail == .video(site: .bilibili, quality: "画质优先", danmakuToASS: false))
        #expect(first.status == .completed)
        #expect(first.completedAt != nil)
        await coordinator.stop()
    }

    @Test func restoredVideoUsesSourceSiteAndGlobalQuality() throws {
        let source = try #require(URL(string: "https://www.youtube.com/watch?v=fixture"))
        let snapshot = EngineTaskSnapshot(
            engineTaskID: "restored", name: "示例视频.mkv", totalBytes: nil,
            receivedBytes: 20, downloadRate: 0, uploadRate: 0, status: .postProcessing,
            connections: 0, savePath: nil, sourceURL: source, errorMessage: nil
        )

        let tasks = EngineSnapshotMerger.merge(
            tasks: [], snapshots: [.video: [snapshot]], now: .now,
            videoConfiguration: VideoEngineConfiguration(quality: .best)
        )

        let task = try #require(tasks.first)
        #expect(task.detail == .video(site: .youtube, quality: "画质优先", danmakuToASS: true))
        #expect(TaskPresentation(task: task).progressText.contains("合并音视频"))
    }

    @Test func settingsMapEveryVideoOptionAndPersistCaptions() throws {
        let name = "mulee.video-options.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsModel(defaults: defaults)
        #expect(VideoEngineConfiguration.configuration(from: settings) == VideoEngineConfiguration())
        settings.videoQuality = .best
        settings.ytDlpChannel = .nightly
        settings.updateBeforeRetry = false
        settings.danmakuToASS = false
        settings.ccSubtitles = false

        let configuration = VideoEngineConfiguration.configuration(from: settings)

        #expect(configuration == VideoEngineConfiguration(
            quality: .best, channel: .nightly, updateBeforeRetry: false,
            danmaku: false, closedCaptions: false
        ))
        #expect(SettingsModel(defaults: defaults).ccSubtitles == false)
    }

    @Test func videoStatusExplainsPreparationFailureAndMissingFFmpeg() {
        #expect(EngineStatusPresentation.videoTitle(for: .running) == "就绪")
        #expect(EngineStatusPresentation.videoTitle(for: .preparing) == "正在准备")
        #expect(EngineStatusPresentation.videoTitle(for: .failed("工具下载失败")) == "启动失败：工具下载失败")
        let missing = EngineStatusPresentation.videoReadyState(ffmpegURL: nil)
        #expect(missing == .missingFFmpeg)
        #expect(EngineStatusPresentation.videoTitle(for: missing) == "缺少 ffmpeg，音视频合并不可用")
        #expect(EngineStatusPresentation.videoReadyState(ffmpegURL: URL(filePath: "/opt/homebrew/bin/ffmpeg")) == .running)
    }

    @Test func httpFailureDoesNotBlockVideoRouting() async {
        let model = AppModel(tasks: [])
        let video = FakeEngine(kind: .video)
        let coordinator = DownloadCoordinator(model: model, engines: [FakeEngine(startError: .binaryNotFound), video])

        await coordinator.start(options: EngineOptions(downloadDirectory: URL(filePath: "/tmp/Mulee")))
        await coordinator.add(links: LinkParser.parse("https://www.youtube.com/watch?v=fixture"), autoExtract: false)

        #expect(await video.isRunning)
        #expect(model.engineStates[.video] == .running)
        #expect(model.tasks.first?.status == .queued)
        await coordinator.stop()
    }

    @Test func managedVideoEngineStartsWithoutFFmpeg() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Mulee-video-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let binary = Data("#!/bin/sh\nexit 0\n".utf8)
        let digest = SHA256.hash(data: binary).map { byte in
            let hex = String(byte, radix: 16)
            return byte < 0x10 ? "0" + hex : hex
        }.joined()
        for name in ["yt-dlp-stable", "deno"] {
            let file = bin.appendingPathComponent(name)
            try binary.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            let record: [String: Any] = ["version": "fixture", "updatedAt": 0, "sha256": digest]
            try JSONSerialization.data(withJSONObject: record).write(to: bin.appendingPathComponent(name + ".json"))
        }
        let bootstrap = VideoEngineBootstrap(directory: root, allowHomebrewFallback: false, ffmpegURL: nil)

        let engine = try await bootstrap.makeEngine(configuration: VideoEngineConfiguration())
        try await engine.start(options: EngineOptions(downloadDirectory: root.appendingPathComponent("downloads")))
        #expect(try await engine.snapshots().isEmpty)
        #expect(EngineStatusPresentation.videoReadyState(ffmpegURL: bootstrap.ffmpegURL) == .missingFFmpeg)
        await engine.stop()
    }
}
