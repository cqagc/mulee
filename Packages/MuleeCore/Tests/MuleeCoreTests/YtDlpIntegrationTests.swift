import Foundation
import Testing
@testable import MuleeCore

@Suite(.serialized, .enabled(if: YtDlpIntegrationFixture.available, "需要本机 yt-dlp 和 ffmpeg"))
struct YtDlpIntegrationTests {
    @Test func genericDownloadPauseResumeTrashAndRecovery() async throws {
        try await YtDlpIntegrationFixture.withFixture { fixture in
            let engine = fixture.engine
            try await engine.start(options: fixture.options)
            let id = try await engine.add(link: fixture.link(), directory: nil)
            let first = try await YtDlpIntegrationFixture.waitFor(engine, id: id) {
                $0.receivedBytes > 32_768 && $0.status == .downloading
            }
            #expect(first.totalBytes ?? 0 > first.receivedBytes)
            #expect(first.downloadRate > 0)
            let state = fixture.state.appendingPathComponent("jobs.json")
            let before = try state.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            try await Task.sleep(for: .milliseconds(200))
            #expect(try state.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == before)
            try await engine.pause(id)
            #expect(try await engine.snapshots().first?.status == .paused)
            let parts = try FileManager.default.contentsOfDirectory(at: fixture.downloads, includingPropertiesForKeys: nil)
            let part = try #require(parts.first { $0.pathExtension == "part" })
            let size = try Data(contentsOf: part).count
            #expect(size > 0, Comment(rawValue: "暂停进度 \(first.receivedBytes)，实际 part \(part.path)，大小 \(size)"))
            let unrelated = fixture.downloads.appendingPathComponent("unrelated.part")
            try Data("keep".utf8).write(to: unrelated)
            await engine.stop()

            let recovered = fixture.makeEngine()
            do {
                try await recovered.start(options: fixture.options)
                #expect(try await recovered.snapshots().first?.id == id)
                #expect(try await recovered.snapshots().first?.status == .paused)
                try await recovered.resume(id)
                let done = try await YtDlpIntegrationFixture.waitFor(recovered, id: id) { $0.status == .completed }
                let file = try #require(done.savePath)
                #expect(file.pathExtension == "mp4")
                // 下载中的文件带任务前缀，完成后去掉前缀。
                #expect(part.lastPathComponent == id + "-" + file.lastPathComponent + ".part")
                #expect(!file.lastPathComponent.hasPrefix(id))
                #expect(try Data(contentsOf: file) == fixture.payload)
                #expect(await fixture.server.rangeRequests > 0)
                try await recovered.remove(id, deleteFiles: true)
                #expect(try await recovered.snapshots().isEmpty)
                #expect(!FileManager.default.fileExists(atPath: file.path))
                #expect(FileManager.default.fileExists(atPath: unrelated.path))
                #expect(try YtDlpIntegrationFixture.removeTrashed(file.lastPathComponent))
                await recovered.stop()
            } catch {
                await recovered.stop()
                throw error
            }
        }
    }

    @Test func activeAndQueuedJobsResumeAfterRestart() async throws {
        try await YtDlpIntegrationFixture.withFixture { fixture in
            let engine = fixture.engine
            try await engine.start(options: fixture.options)
            let first = try await engine.add(link: fixture.link(), directory: nil)
            _ = try await YtDlpIntegrationFixture.waitFor(engine, id: first) { $0.receivedBytes > 32_768 }
            let second = try await engine.add(link: fixture.link("second.mp4"), directory: nil)
            #expect(try await engine.snapshots().first(where: { $0.id == second })?.status == .queued)
            await engine.stop()
            let recovered = fixture.makeEngine()
            do {
                try await recovered.start(options: fixture.options)
                _ = try await YtDlpIntegrationFixture.waitFor(recovered, id: first) { $0.status == .completed }
                _ = try await YtDlpIntegrationFixture.waitFor(recovered, id: second) { $0.status == .completed }
                #expect(try await recovered.snapshots().count == 2)
                await recovered.stop()
                let finished = fixture.makeEngine()
                try await finished.start(options: fixture.options)
                #expect(try await finished.snapshots().allSatisfy { $0.status == .completed })
                await finished.stop()
            } catch {
                await recovered.stop()
                throw error
            }
        }
    }

    @Test func unsupportedAndFailedJobsPersist() async throws {
        try await YtDlpIntegrationFixture.withFixture { fixture in
            let engine = fixture.engine
            try await engine.start(options: fixture.options)
            let url = try #require(URL(string: "http://127.0.0.1:\(fixture.port)/missing.bin"))
            await #expect(throws: EngineError.unsupportedLink) {
                try await engine.add(link: .http(url: url, decodedFromThunder: false, original: url.absoluteString))
            }
            let id = try await engine.add(link: .video(url: url, site: .other, original: url.absoluteString))
            let failed = try await YtDlpIntegrationFixture.waitFor(engine, id: id) { $0.status == .failed }
            #expect(failed.errorMessage?.contains(String(localized: "视频不存在或已删除。", bundle: .module)) == true)
            await engine.stop()
            let recovered = fixture.makeEngine()
            do {
                try await recovered.start(options: fixture.options)
                #expect(try await recovered.snapshots().first?.status == .failed)
                await recovered.stop()
            } catch {
                await recovered.stop()
                throw error
            }
        }
    }

    @Test func removingIncompleteTaskTrashesOnlyOwnedFiles() async throws {
        try await YtDlpIntegrationFixture.withFixture { fixture in
            let engine = fixture.engine
            try await engine.start(options: fixture.options)
            let id = try await engine.add(link: fixture.link())
            _ = try await YtDlpIntegrationFixture.waitFor(engine, id: id) { $0.receivedBytes > 32_768 }
            try await engine.pause(id)
            let files = try FileManager.default.contentsOfDirectory(at: fixture.downloads, includingPropertiesForKeys: nil)
            try await engine.remove(id, deleteFiles: true)
            #expect(!files.isEmpty)
            for file in files {
                #expect(!FileManager.default.fileExists(atPath: file.path))
                #expect(try YtDlpIntegrationFixture.removeTrashed(file.lastPathComponent))
            }
        }
    }

    @Test func bestQualityConfigurationAndCustomDirectory() async throws {
        try await YtDlpIntegrationFixture.withFixture { fixture in
            let engine = fixture.engine
            try await engine.start(options: fixture.options)
            await engine.configure(quality: .best, cookiesURL: nil)
            let directory = fixture.root.appendingPathComponent("custom")
            let id = try await engine.add(link: fixture.link("fixture.mp4"), directory: directory)
            let done = try await YtDlpIntegrationFixture.waitFor(engine, id: id) { $0.status == .completed }
            let file = try #require(done.savePath)
            #expect(file.pathExtension == "mkv")
            #expect(file.deletingLastPathComponent().path == directory.path)
            #expect(done.receivedBytes > 0)
        }
    }


    @Test func changingConcurrencyAndRateKeepsTasksResumable() async throws {
        try await YtDlpIntegrationFixture.withFixture { fixture in
            let engine = fixture.engine
            var options = fixture.options
            options.downloadLimit = 256 * 1024
            try await engine.start(options: options)
            let first = try await engine.add(link: fixture.link())
            _ = try await YtDlpIntegrationFixture.waitFor(engine, id: first) { $0.receivedBytes > 32_768 }
            let second = try await engine.add(link: fixture.link("slow-second.mp4"))
            #expect(try await engine.snapshots().first(where: { $0.id == second })?.status == .queued)
            options.maxConcurrentDownloads = 2
            try await engine.apply(options: options)
            _ = try await YtDlpIntegrationFixture.waitFor(engine, id: second) { $0.receivedBytes > 32_768 }
            let active = try await engine.snapshots().filter { $0.status == .downloading }
            #expect(active.count == 2)
            try await engine.pause(first)
            #expect(try await engine.snapshots().first(where: { $0.id == first })?.status == .paused)
            options.downloadLimit = 0
            try await engine.apply(options: options)
            _ = try await YtDlpIntegrationFixture.waitFor(engine, id: second) { $0.status == .completed }
            try await engine.resume(first)
            _ = try await YtDlpIntegrationFixture.waitFor(engine, id: first) { $0.status == .completed }
        }
    }


    @Test func hevcCompatibilityUsesHvc1Tag() async throws {
        try await YtDlpIntegrationFixture.withFixture { fixture in
            let source = fixture.root.appendingPathComponent("fixture.mp4")
            let generated = try await YtDlpProcess.capture(binary: YtDlpIntegrationFixture.ffmpeg, arguments: [
                "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "color=size=64x64:rate=10",
                "-t", "0.3", "-c:v", "libx265", "-x265-params", "pools=1:log-level=error",
                "-tag:v", "hev1", source.path
            ])
            try #require(generated.status == 0, Comment(rawValue: generated.output))
            let binary = fixture.root.appendingPathComponent("fake-yt-dlp")
            let script = #"""
            #!/bin/sh
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --paths) directory="$2"; shift 2 ;;
                    --output) template="$2"; shift 2 ;;
                    *) shift ;;
                esac
            done
            prefix="${template%%\%*}"
            file="$directory/${prefix}fixture.mp4"
            /bin/cp "${0%/*}/fixture.mp4" "$file"
            printf '%s\n' 'MULEE:{"event":"metadata","vcodec":"hevc","title":"示例视频"}'
            printf 'MULEE:{"event":"file","path":"%s"}\n' "$file"
            """#
            try Data(script.utf8).write(to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
            let engine = YtDlpEngine(
                stateDirectory: fixture.root.appendingPathComponent("hevc-state"), binaryURL: binary,
                installer: nil, ffmpegURL: YtDlpIntegrationFixture.ffmpeg, updatesEnabled: false
            )
            do {
                try await engine.start(options: fixture.options)
                let id = try await engine.add(link: fixture.link())
                let done = try await YtDlpIntegrationFixture.waitFor(engine, id: id) { $0.status == .completed }
                let file = try #require(done.savePath)
                let probe = try await YtDlpProcess.capture(binary: YtDlpIntegrationFixture.ffmpeg, arguments: [
                    "-hide_banner", "-i", file.path
                ])
                #expect(probe.output.contains("hvc1"))
                #expect(!probe.output.contains("hev1"))
                await engine.stop()
            } catch {
                await engine.stop()
                throw error
            }
        }
    }

}
