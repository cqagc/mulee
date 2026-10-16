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
        let temporaryDefaults = try TemporaryDefaults(prefix: "mulee.video-options.")
        defer { temporaryDefaults.clean() }
        let defaults = temporaryDefaults.defaults
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

    @Test func preparingTaskAppearsImmediatelyAndIsSubmittedWhenReady() async throws {
        let model = AppModel(tasks: [])
        let video = FakeEngine(kind: .video)
        let gate = VideoEnginePreparationGate()
        let coordinator = DownloadCoordinator(model: model, engines: [], videoEngineFactory: { _ in
            await gate.wait()
            return video
        })
        await coordinator.start(options: EngineOptions(downloadDirectory: URL(filePath: "/tmp/Mulee")))
        let links = LinkParser.parse("https://www.youtube.com/watch?v=fixture")
        let directory = URL(filePath: "/tmp/Mulee-custom-video")

        await coordinator.add(links: links, autoExtract: true, directory: directory)

        let task = try #require(model.tasks.first)
        #expect(task.status == .queued)
        #expect(task.engineTaskID == nil)
        #expect(task.postDownload.autoExtract)
        #expect(TaskPresentation(task: task).statusSubtitle == "正在准备视频工具")
        #expect(await video.addedLinks.isEmpty)
        gate.release()
        try await waitUntil { model.tasks.first?.engineTaskID != nil }
        #expect(model.tasks.first?.id == task.id)
        #expect(model.tasks.first?.engineTaskID == "task-1")
        #expect(await video.addedLinks == links)
        #expect(await video.directories == [directory])
        #expect(TaskPresentation(task: model.tasks[0]).statusSubtitle == "等待空位")
        await coordinator.stop()
    }

    @Test func preparationFailureMarksWaitingTasksFailed() async throws {
        let model = AppModel(tasks: [])
        let gate = VideoEnginePreparationGate()
        let coordinator = DownloadCoordinator(model: model, engines: [], videoEngineFactory: { _ in
            await gate.wait()
            throw EngineError.invalidResponse("工具下载失败")
        })
        await coordinator.start(options: EngineOptions(downloadDirectory: URL(filePath: "/tmp/Mulee")))
        await coordinator.add(links: LinkParser.parse("https://www.youtube.com/watch?v=fixture"), autoExtract: false)

        gate.release()
        try await waitUntil { model.tasks.first?.status == .failed }

        #expect(model.tasks.first?.engineTaskID == nil)
        #expect(model.tasks.first?.errorMessage?.contains("工具下载失败") == true)
        await coordinator.add(links: LinkParser.parse("https://www.youtube.com/watch?v=fixture2"), autoExtract: false)
        #expect(model.tasks.allSatisfy { $0.status == .failed })
        await coordinator.stop()
    }

    @Test func deletingDuringPreparationDoesNotSubmitToEngine() async throws {
        let model = AppModel(tasks: [])
        let video = FakeEngine(kind: .video)
        let gate = VideoEnginePreparationGate()
        let coordinator = DownloadCoordinator(model: model, engines: [], videoEngineFactory: { _ in
            await gate.wait()
            return video
        })
        await coordinator.start(options: EngineOptions(downloadDirectory: URL(filePath: "/tmp/Mulee")))
        await coordinator.add(links: LinkParser.parse("https://www.youtube.com/watch?v=fixture"), autoExtract: false)
        let id = try #require(model.tasks.first?.id)

        await coordinator.remove(id)
        gate.release()
        try await waitUntil { model.engineStates[.video] == .running }
        // stop 等待完整的准备及提交循环，确保没有迟到的 add。
        await coordinator.stop()

        #expect(model.tasks.isEmpty)
        #expect(await video.addedLinks.isEmpty)
    }

    @Test(arguments: [false, true]) func pausedPreparationWaitsForUserToResume(resumeWhilePreparing: Bool) async throws {
        let model = AppModel(tasks: [])
        let video = FakeEngine(kind: .video)
        let gate = VideoEnginePreparationGate()
        let coordinator = DownloadCoordinator(model: model, engines: [], videoEngineFactory: { _ in
            await gate.wait()
            return video
        })
        await coordinator.start(options: EngineOptions(downloadDirectory: URL(filePath: "/tmp/Mulee")))
        await coordinator.add(links: LinkParser.parse("https://www.youtube.com/watch?v=fixture"), autoExtract: false)
        let id = try #require(model.tasks.first?.id)

        await coordinator.pause(id)
        if resumeWhilePreparing {
            await coordinator.resume(id)
            #expect(model.tasks.first?.status == .queued)
            #expect(await video.addedLinks.isEmpty)
        }
        gate.release()
        if resumeWhilePreparing {
            try await waitUntil { model.tasks.first?.engineTaskID != nil }
        } else {
            try await waitUntil { model.engineStates[.video] == .running }
            #expect(model.tasks.first?.status == .paused)
            #expect(await video.addedLinks.isEmpty)
            await coordinator.resume(id)
        }

        #expect(model.tasks.first?.engineTaskID == "task-1")
        #expect(model.tasks.first?.status == .queued)
        #expect(await video.addedLinks.count == 1)
        await coordinator.stop()
    }

    @Test func waitingHistorySurvivesExitAndBecomesRetryableFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Mulee-video-history-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(tasks: [])
        model.loadTaskHistory(from: TaskHistoryStore(directory: root))
        let gate = VideoEnginePreparationGate()
        let video = FakeEngine(kind: .video)
        let coordinator = DownloadCoordinator(model: model, engines: [], videoEngineFactory: { _ in
            await gate.wait()
            return video
        })
        await coordinator.start(options: EngineOptions(downloadDirectory: root))
        await coordinator.add(links: LinkParser.parse("https://www.youtube.com/watch?v=fixture"), autoExtract: false)
        let original = try #require(model.tasks.first)
        model.flushTaskHistory()
        let stopping = Task { await coordinator.stop() }
        await Task.yield()
        gate.release()
        await stopping.value

        let restored = AppModel(tasks: [])
        restored.loadTaskHistory(from: TaskHistoryStore(directory: root))
        #expect(restored.tasks.first?.id == original.id)
        #expect(restored.tasks.first?.sourceLink == original.sourceLink)
        let restarted = DownloadCoordinator(model: restored, engines: [])
        await restarted.start(options: EngineOptions(downloadDirectory: root))

        #expect(restored.tasks.first?.status == .failed)
        #expect(restored.tasks.first?.errorMessage?.contains("可以重新下载") == true)
        await restarted.stop()
    }

    @Test func managedVideoEngineUsesBothInstalledTools() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Mulee-video-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin")
        try seedTools(["yt-dlp-stable", "deno", "ffmpeg", "ffprobe"], in: bin)
        let bootstrap = VideoEngineBootstrap(directory: root, allowHomebrewFallback: false)

        let engine = try await bootstrap.makeEngine(configuration: VideoEngineConfiguration())
        try await engine.start(options: EngineOptions(downloadDirectory: root.appendingPathComponent("downloads")))
        #expect(try await engine.snapshots().isEmpty)
        #expect(await bootstrap.ffmpegURL == bin.appendingPathComponent("ffmpeg"))
        #expect(await bootstrap.ffmpegPreparationError == nil)
        await engine.stop()
    }

    /// ffmpeg 准备失败不拖垮视频引擎：照常启动并接收任务，只是状态提示不能合并音视频。
    @Test func missingFFmpegIsReportedOnlyAfterManagedInstallationFails() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Mulee-video-missing-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin")
        try seedTools(["yt-dlp-stable", "deno"], in: bin)
        let gate = VideoEnginePreparationGate()
        let installer = ManagedToolInstaller(directory: bin) { _, _ in
            await gate.wait()
            throw EngineError.invalidResponse("ffmpeg 下载失败")
        }
        let bootstrap = VideoEngineBootstrap(directory: root, allowHomebrewFallback: false, installer: installer)
        let model = AppModel(tasks: [])
        let coordinator = DownloadCoordinator(model: model, engines: [], videoBootstrap: bootstrap)
        await coordinator.start(options: EngineOptions(downloadDirectory: root))
        await coordinator.add(links: LinkParser.parse("https://www.youtube.com/watch?v=fixture"), autoExtract: false)

        #expect(model.engineStates[.video] == .preparing)
        #expect(model.tasks.first?.status == .queued)
        gate.release()
        try await waitUntil { model.engineStates[.video] == .missingFFmpeg }

        try await waitUntil { model.tasks.first?.engineTaskID != nil }
        #expect(model.tasks.first?.errorMessage?.contains("ffmpeg") != true)
        await coordinator.stop()
    }

    @Test func ffmpegResolutionPrefersManagedPairToHomebrew() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Mulee-video-order-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin")
        try seedTools(["ffmpeg", "ffprobe"], in: bin)
        let bootstrap = VideoEngineBootstrap(directory: root, allowHomebrewFallback: true, homebrewLookup: { name in
            URL(filePath: "/fixture/homebrew/" + name)
        })

        #expect(try await bootstrap.resolveFFmpeg() == bin.appendingPathComponent("ffmpeg"))
    }

    @Test func ffmpegResolutionUsesDebugHomebrewBeforeDownload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Mulee-video-brew-\(UUID())")
        let installer = ManagedToolInstaller(directory: root) { _, _ in
            throw EngineError.invalidResponse("不应下载")
        }
        let bootstrap = VideoEngineBootstrap(allowHomebrewFallback: true, installer: installer, homebrewLookup: { name in
            URL(filePath: "/fixture/homebrew/" + name)
        })

        #expect(try await bootstrap.resolveFFmpeg() == URL(filePath: "/fixture/homebrew/ffmpeg"))
    }

    @Test func ffmpegResolutionDownloadsWhenHomebrewIsDisabledOrMissing() async throws {
        for allowFallback in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("Mulee-video-download-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let pair = AsyncStream<URL>.makeStream()
            let installer = ManagedToolInstaller(directory: root) { url, _ in
                pair.continuation.yield(url)
                pair.continuation.finish()
                throw EngineError.invalidResponse("fixture download failure")
            }
            let bootstrap = VideoEngineBootstrap(
                allowHomebrewFallback: allowFallback, installer: installer,
                homebrewLookup: { name in allowFallback ? nil : URL(filePath: "/fixture/homebrew/" + name) }
            )

            await #expect(throws: EngineError.self) { try await bootstrap.resolveFFmpeg() }
            var iterator = pair.stream.makeAsyncIterator()
            #expect(await iterator.next() == ManagedTool.ffmpeg.downloadURL)
        }
    }

    @Test func incompleteManagedPairInstallsProbeInSameDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Mulee-video-probe-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try seedTools(["ffmpeg"], in: root)
        let pair = AsyncStream<URL>.makeStream()
        let installer = ManagedToolInstaller(directory: root) { url, _ in
            pair.continuation.yield(url)
            pair.continuation.finish()
            throw EngineError.invalidResponse("fixture download failure")
        }
        let bootstrap = VideoEngineBootstrap(allowHomebrewFallback: true, installer: installer, homebrewLookup: { name in
            URL(filePath: "/fixture/homebrew/" + name)
        })

        await #expect(throws: EngineError.self) { try await bootstrap.resolveFFmpeg() }
        var iterator = pair.stream.makeAsyncIterator()
        #expect(await iterator.next() == ManagedTool.ffprobe.downloadURL)
    }

    private func seedTools(_ names: [String], in bin: URL) throws {
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let binary = Data("#!/bin/sh\nexit 0\n".utf8)
        let digest = SHA256.hash(data: binary).map { byte in
            let hex = String(byte, radix: 16)
            return byte < 0x10 ? "0" + hex : hex
        }.joined()
        for name in names {
            let file = bin.appendingPathComponent(name)
            try binary.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            let record: [String: Any] = ["version": "fixture", "updatedAt": 0, "sha256": digest]
            try JSONSerialization.data(withJSONObject: record).write(to: bin.appendingPathComponent(name + ".json"))
        }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition())
    }
}
