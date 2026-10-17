import CryptoKit
import Darwin
import Foundation
import Testing
@testable import MuleeCore

struct YtDlpConfigurationTests {
    @Test func increasingConcurrencyStartsQueuedWorkerWithoutReplacingExistingProcess() async throws {
        try await withConcurrencyEngine { engine, directory in
            var options = EngineOptions(downloadDirectory: directory, maxConcurrentDownloads: 1, diskCacheMegabytes: 1)
            try await engine.start(options: options)
            let first = try await engine.add(link: concurrencyLink("first"))
            let firstPID = try await processID(directory, id: first)
            let second = try await engine.add(link: concurrencyLink("second"))
            #expect(try await engine.snapshots().first(where: { $0.id == second })?.status == .queued)

            options.maxConcurrentDownloads = 2
            try await engine.apply(options: options)
            _ = try await processID(directory, id: second)

            #expect(kill(firstPID, 0) == 0)
            #expect(try await processID(directory, id: first) == firstPID)
            #expect(try starts(directory, id: first) == [String(firstPID)])
            #expect(try await engine.snapshots().filter { $0.status == .downloading }.count == 2)
        }
    }

    @Test func loweringConcurrencyRequeuesNewestDownloadAndKeepsPostProcessing() async throws {
        try await withConcurrencyEngine { engine, directory in
            var options = EngineOptions(downloadDirectory: directory, maxConcurrentDownloads: 3, diskCacheMegabytes: 1)
            try await engine.start(options: options)
            let first = try await engine.add(link: concurrencyLink("first"))
            let firstPID = try await processID(directory, id: first)
            let second = try await engine.add(link: concurrencyLink("second"))
            let secondPID = try await processID(directory, id: second)
            let post = try await engine.add(link: concurrencyLink("post"))
            let postPID = try await processID(directory, id: post)
            _ = try await YtDlpIntegrationFixture.waitFor(engine, id: post) { $0.status == .postProcessing }

            options.maxConcurrentDownloads = 2
            try await engine.apply(options: options)

            let snapshots = try await engine.snapshots()
            #expect(snapshots.first(where: { $0.id == first })?.status == .downloading)
            #expect(snapshots.first(where: { $0.id == second })?.status == .queued)
            #expect(snapshots.first(where: { $0.id == post })?.status == .postProcessing)
            #expect(kill(firstPID, 0) == 0)
            #expect(kill(secondPID, 0) != 0)
            #expect(kill(postPID, 0) == 0)
            #expect(try starts(directory, id: post) == [String(postPID)])
            try Data().write(to: directory.appendingPathComponent(post + ".finish"))
            _ = try await YtDlpIntegrationFixture.waitFor(engine, id: post) { $0.status == .completed }
            _ = try await YtDlpIntegrationFixture.waitFor(engine, id: second) { $0.status == .downloading }
            #expect(kill(firstPID, 0) == 0)
        }
    }

    @Test func postProcessingAboveNewLimitFinishesBeforeQueuedWorkStarts() async throws {
        try await withConcurrencyEngine { engine, directory in
            var options = EngineOptions(downloadDirectory: directory, maxConcurrentDownloads: 2)
            try await engine.start(options: options)
            let first = try await engine.add(link: concurrencyLink("post"))
            let firstPID = try await processID(directory, id: first)
            _ = try await YtDlpIntegrationFixture.waitFor(engine, id: first) { $0.status == .postProcessing }
            let second = try await engine.add(link: concurrencyLink("post"))
            let secondPID = try await processID(directory, id: second)
            _ = try await YtDlpIntegrationFixture.waitFor(engine, id: second) { $0.status == .postProcessing }

            options.maxConcurrentDownloads = 1
            try await engine.apply(options: options)
            let queued = try await engine.add(link: concurrencyLink("next"))

            #expect(kill(firstPID, 0) == 0)
            #expect(kill(secondPID, 0) == 0)
            #expect(try await engine.snapshots().first(where: { $0.id == queued })?.status == .queued)
            try Data().write(to: directory.appendingPathComponent(first + ".finish"))
            _ = try await YtDlpIntegrationFixture.waitFor(engine, id: first) { $0.status == .completed }
            #expect(try await engine.snapshots().first(where: { $0.id == queued })?.status == .queued)
            try Data().write(to: directory.appendingPathComponent(second + ".finish"))
            _ = try await YtDlpIntegrationFixture.waitFor(engine, id: second) { $0.status == .completed }
            _ = try await processID(directory, id: queued)
        }
    }

    @Test(arguments: [0, -1])
    func invalidConcurrencyDoesNotTerminateExistingWorker(limit: Int) async throws {
        try await withConcurrencyEngine { engine, directory in
            var options = EngineOptions(downloadDirectory: directory, maxConcurrentDownloads: 1)
            try await engine.start(options: options)
            let id = try await engine.add(link: concurrencyLink("first"))
            let pid = try await processID(directory, id: id)

            options.maxConcurrentDownloads = limit
            await #expect(throws: EngineError.self) { try await engine.apply(options: options) }

            #expect(kill(pid, 0) == 0)
            #expect(try starts(directory, id: id) == [String(pid)])
            #expect(try await engine.snapshots().first?.status == .downloading)
        }
    }

    @Test func channelAndQualityChangesUseNewToolWithoutRestartingEngine() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("YtDlp-config-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = ManagedToolInstaller(directory: root.appendingPathComponent("bin")) { url, destination in
            let nightly = url.absoluteString.contains("nightly")
            let payload = Data(Self.script(marker: nightly ? "nightly" : "stable").utf8)
            if url.lastPathComponent == "SHA2-256SUMS" {
                let digest = SHA256.hash(data: payload).map { byte in
                    let hex = String(byte, radix: 16)
                    return byte < 0x10 ? "0" + hex : hex
                }.joined()
                try Data((digest + "  yt-dlp_macos\n").utf8).write(to: destination)
            } else {
                try payload.write(to: destination)
            }
        }
        let engine = YtDlpEngine(stateDirectory: root.appendingPathComponent("state"), installer: installer)
        do {
            try await engine.start(options: EngineOptions(downloadDirectory: root.appendingPathComponent("downloads")))
            let url = try #require(URL(string: "https://example.invalid/video"))
            let link = ParsedLink.video(url: url, site: .bilibili, original: url.absoluteString)
            let first = try await engine.add(link: link)
            _ = try await YtDlpIntegrationFixture.waitFor(engine, id: first) { $0.status == .completed }

            try await engine.configure(
                quality: .best, cookiesURL: nil,
                subtitles: YtDlpSubtitles(danmaku: true, closedCaptions: true),
                channel: .nightly, updatesEnabled: false
            )
            try await engine.apply(options: EngineOptions(
                downloadDirectory: root.appendingPathComponent("downloads"), maxConcurrentDownloads: 2, diskCacheMegabytes: 1
            ))
            let second = try await engine.add(link: link)
            _ = try await YtDlpIntegrationFixture.waitFor(engine, id: second) { $0.status == .completed }
            let arguments = try String(contentsOf: root.appendingPathComponent("downloads/arguments"), encoding: .utf8)

            #expect(arguments.contains("--buffer-size 524288 --no-resize-buffer"))
            #expect(arguments.contains("--continue"))
            #expect(arguments.contains("nightly"))
            #expect(arguments.contains("mkv"))
            #expect(arguments.contains("--write-subs"))
            #expect(arguments.contains("all"))
            #expect(arguments.contains("en_US.UTF-8"))
            #expect(try await engine.snapshots().count == 2)
            #expect(try await installer.installedURL(for: .ytDlp(channel: .nightly)) != nil)
            await engine.stop()

            // 停止期间切换通道，之后启动也必须使用新工具。
            try await engine.configure(
                quality: .compatible, cookiesURL: nil, subtitles: YtDlpSubtitles(),
                channel: .stable, updatesEnabled: false
            )
            try await engine.start(options: EngineOptions(downloadDirectory: root.appendingPathComponent("downloads")))
            let third = try await engine.add(link: link)
            _ = try await YtDlpIntegrationFixture.waitFor(engine, id: third) { $0.status == .completed }
            let restarted = try String(contentsOf: root.appendingPathComponent("downloads/arguments"), encoding: .utf8)
            #expect(restarted.hasPrefix("stable\n"))
            #expect(restarted.contains("mp4"))
            await engine.stop()
        } catch {
            await engine.stop()
            throw error
        }
    }

    @Test func retrySettingChangesAreAppliedAfterStartup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("YtDlp-config-retry-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("yt-dlp")
        let marker = root.appendingPathComponent("updated")
        try Data("#!/bin/sh\necho 'ERROR: fixture failure'\nexit 1\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let engine = YtDlpEngine(
            stateDirectory: root.appendingPathComponent("state"), binaryURL: binary, installer: nil,
            updater: {
                try Data("updated".utf8).write(to: marker)
                return binary
            }
        )
        do {
            try await engine.start(options: EngineOptions(downloadDirectory: root.appendingPathComponent("downloads")))
            let url = try #require(URL(string: "https://example.invalid/video"))
            let link = ParsedLink.video(url: url, site: .other, original: url.absoluteString)
            for enabled in [false, true] {
                try await engine.configure(
                    quality: .compatible, cookiesURL: nil, subtitles: YtDlpSubtitles(),
                    channel: .stable, updatesEnabled: enabled
                )
                let id = try await engine.add(link: link)
                _ = try await YtDlpIntegrationFixture.waitFor(engine, id: id) { $0.status == .failed }
                #expect(FileManager.default.fileExists(atPath: marker.path) == enabled)
            }
            await engine.stop()
        } catch {
            await engine.stop()
            throw error
        }
    }

    private func withConcurrencyEngine(_ body: @Sendable (YtDlpEngine, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("YtDlp-concurrency-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("yt-dlp")
        try Data(Self.concurrencyScript.utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let engine = YtDlpEngine(stateDirectory: root.appendingPathComponent("state"), binaryURL: binary,
                                 installer: nil, updatesEnabled: false)
        do {
            try await body(engine, root.appendingPathComponent("downloads"))
            await engine.stop()
            try await YtDlpIntegrationFixture.checkNoProcesses(root: root)
        } catch {
            await engine.stop()
            try await YtDlpIntegrationFixture.checkNoProcesses(root: root)
            throw error
        }
    }

    private func concurrencyLink(_ name: String) throws -> ParsedLink {
        let url = try #require(URL(string: "https://example.invalid/" + name))
        return .video(url: url, site: .other, original: url.absoluteString)
    }

    private func processID(_ directory: URL, id: String) async throws -> Int32 {
        let marker = directory.appendingPathComponent(id + ".pid")
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return try #require(Int32(String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    private func starts(_ directory: URL, id: String) throws -> [String] {
        try String(contentsOf: directory.appendingPathComponent(id + ".starts"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }

    private static let concurrencyScript = """
    #!/bin/sh
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --paths) directory="$2"; shift 2 ;;
            --output) template="$2"; shift 2 ;;
            *) source="$1"; shift ;;
        esac
    done
    prefix="${template%%\\%*}"
    id="${prefix%-}"
    printf '%s\\n' "$$" >> "$directory/$id.starts"
    printf '%s\\n' "$$" > "$directory/$id.pid"
    case "$source" in
        */post) printf 'MULEE:{"event":"postprocess"}\\n' ;;
    esac
    while [ ! -f "$directory/$id.finish" ]; do /bin/sleep 0.02; done
    file="$directory/${prefix}fixture.mp4"
    printf 'video' > "$file"
    printf 'MULEE:{"event":"file","path":"%s"}\\n' "$file"
    """

    private static func script(marker: String) -> String {
        """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo fixture; exit 0; fi
        arguments="$*"
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --paths) directory="$2"; shift 2 ;;
                --output) template="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        prefix="${template%%\\%*}"
        file="$directory/${prefix}fixture.mp4"
        printf '%s\\n' '\(marker)' "$arguments" "$LANG" > "$directory/arguments"
        /usr/bin/touch "$file"
        printf 'MULEE:{"event":"file","path":"%s"}\\n' "$file"
        """
    }
}
