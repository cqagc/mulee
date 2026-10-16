import CryptoKit
import Darwin
import Foundation
import Testing
@testable import MuleeCore

/// Opt-in live measurements use the same adapters as DownloadCoordinator.stop().
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MULEE_MEASURE_SHUTDOWN"] == "1"))
struct EngineShutdownTests {
    @Test("aria2: idle and active shutdown, session and piece bitmap survive restart")
    func aria2() async throws {
        for active in [false, true] {
            try await Aria2IntegrationFixture.withFixture { fixture in
                var options = fixture.options
                options.downloadLimit = 128 * 1024
                try await fixture.engine.start(options: options)
                var before: EngineTaskSnapshot?
                if active {
                    let id = try await fixture.engine.add(link: fixture.link("slow-shutdown.bin"), directory: nil)
                    before = try await fixture.waitFor(id) { $0.receivedBytes > 1_100_000 && $0.status == .downloading }
                }
                await measure(fixture.engine, name: "aria2", state: active ? "active" : "idle", bytes: before?.receivedBytes ?? 0)
                if let before {
                    let text = try String(contentsOf: fixture.state.appendingPathComponent("aria2.session"), encoding: .utf8)
                    #expect(text.contains("gid=\(before.engineTaskID)"))
                    let path = try #require(before.savePath)
                    #expect(FileManager.default.fileExists(atPath: path.path + ".aria2"))
                    let rangesBeforeRestart = await fixture.server.rangeRequests
                    try await fixture.engine.start(options: fixture.options)
                    let restored = try await fixture.waitFor(before.engineTaskID) { $0.receivedBytes >= before.receivedBytes }
                    #expect(restored.receivedBytes >= before.receivedBytes)
                    let completed = try await fixture.waitFor(before.engineTaskID) { $0.status == .completed }
                    #expect(try Data(contentsOf: #require(completed.savePath)) == fixture.payload)
                    #expect(await fixture.server.rangeRequests > rangesBeforeRestart)
                }
            }
        }
    }

    @Test("amuled: idle and waiting-for-sources shutdown preserve the task and part state")
    func ed2k() async throws {
        let binary = URL(fileURLWithPath: try #require(environment["MULEE_AMULED"]))
        for active in [false, true] {
            let root = try Ed2kTestDirectory()
            let state = root.url.appendingPathComponent("state")
            let settings = Ed2kEngineSettings(
                tcpPort: try ECLoopback.availablePort(), udpPort: try ECLoopback.availablePort(),
                connectToServers: false, enableKad: false
            )
            let engine = Ed2kEngine(stateDirectory: state, binaryURL: binary, settings: settings)
            let options = EngineOptions(downloadDirectory: root.url.appendingPathComponent("downloads"))
            do {
                try await engine.start(options: options)
                var id: String?
                if active {
                    let link = try #require(Ed2kLinkParser.parse(
                        "ed2k://|file|shutdown-test.bin|1048576|0123456789ABCDEF0123456789ABCDEF|/"
                    ))
                    id = try await engine.add(link: link, directory: nil)
                }
                await measure(engine, name: "amuled", state: active ? "waiting" : "idle", bytes: 0)
                if let id {
                    let files = try FileManager.default.contentsOfDirectory(
                        at: state.appendingPathComponent("Temp"), includingPropertiesForKeys: nil
                    )
                    #expect(files.contains { $0.lastPathComponent.hasSuffix(".part.met") })
                    try await engine.start(options: options)
                    let restored = try #require(try await engine.snapshots().first { $0.engineTaskID == id })
                    #expect(restored.status == .waitingForSources)
                    #expect(restored.receivedBytes == 0)
                }
                await engine.stop()
                try root.remove()
            } catch {
                await engine.stop()
                try root.remove()
                throw error
            }
        }
    }

    @Test("yt-dlp: active part file and job survive shutdown and complete after restart")
    func video() async throws {
        try #require(YtDlpIntegrationFixture.available, "yt-dlp and ffmpeg are required")
        for active in [false, true] {
            try await YtDlpIntegrationFixture.withFixture { fixture in
                try await fixture.engine.start(options: fixture.options)
                var before: EngineTaskSnapshot?
                if active {
                    let id = try await fixture.engine.add(link: fixture.link(), directory: nil)
                    before = try await YtDlpIntegrationFixture.waitFor(fixture.engine, id: id) {
                        $0.receivedBytes > 32_768 && $0.status == .downloading
                    }
                }
                await measure(fixture.engine, name: "yt-dlp", state: active ? "active" : "idle", bytes: before?.receivedBytes ?? 0)
                if let before {
                    let jobs = try JSONDecoder().decode(
                        [YtDlpJob].self, from: Data(contentsOf: fixture.state.appendingPathComponent("jobs.json"))
                    )
                    #expect(jobs.first { $0.id == before.id }?.receivedBytes ?? 0 >= before.receivedBytes)
                    let parts = try FileManager.default.contentsOfDirectory(at: fixture.downloads, includingPropertiesForKeys: nil)
                    let part = try #require(parts.first { $0.pathExtension == "part" })
                    #expect(try Data(contentsOf: part).count >= before.receivedBytes)
                    let rangesBeforeRestart = await fixture.server.rangeRequests
                    let recovered = fixture.makeEngine()
                    do {
                        try await recovered.start(options: fixture.options)
                        let restored = try await YtDlpIntegrationFixture.waitFor(recovered, id: before.id) {
                            $0.receivedBytes >= before.receivedBytes
                        }
                        #expect(restored.receivedBytes >= before.receivedBytes)
                        let done = try await YtDlpIntegrationFixture.waitFor(recovered, id: before.id) { $0.status == .completed }
                        #expect(try Data(contentsOf: #require(done.savePath)) == fixture.payload)
                        #expect(await fixture.server.rangeRequests > rangesBeforeRestart)
                        await recovered.stop()
                    } catch {
                        await recovered.stop()
                        throw error
                    }
                }
            }
        }
    }

    @Test("torrentd: idle plus Debian public swarm, flushed resume survives restart")
    func torrent() async throws {
        let root = URL(fileURLWithPath: try #require(environment["MULEE_SHUTDOWN_ROOT"]))
        let binary = URL(fileURLWithPath: try #require(environment["MULEE_TORRENTD"]))
        var scenarios: [(String, URL?)] = [("idle", nil)]
        if let path = environment["MULEE_SHUTDOWN_TORRENT"] {
            scenarios.append(("debian", URL(fileURLWithPath: path)))
        }
        // A loopback seed also makes progress persistence verifiable without internet access.
        let payload = Data(repeating: 65, count: 4 * 1024 * 1024)
        let torrentURL = root.appendingPathComponent("fixture.torrent")
        let pieces = stride(from: 0, to: payload.count, by: 16_384).reduce(into: Data()) { data, offset in
            data.append(contentsOf: Insecure.SHA1.hash(data: payload.subdata(in: offset..<min(offset + 16_384, payload.count))))
        }
        let info = Data("d6:lengthi\(payload.count)e4:name10:Ubuntu.txt12:piece lengthi16384e6:pieces".utf8)
            + TorrentFixtures.bytes(pieces) + Data("e".utf8)
        try (Data("d4:info".utf8) + info + Data("e".utf8)).write(to: torrentURL)
        let seedDownloads = root.appendingPathComponent("seed-downloads")
        try FileManager.default.createDirectory(at: seedDownloads, withIntermediateDirectories: true)
        try payload.write(to: seedDownloads.appendingPathComponent("Ubuntu.txt"))
        let settings = TorrentEngineSettings(listenPort: 0, dht: false, lsd: false, portMapping: false)
        let seed = TorrentEngine(stateDirectory: root.appendingPathComponent("seed"), binaryURL: binary, settings: settings)
        do {
            try await seed.start(options: EngineOptions(downloadDirectory: seedDownloads))
            let seedID = try await seed.add(link: .torrentFile(url: torrentURL, original: torrentURL.path), directory: nil)
            _ = try await waitFor(seed, id: seedID) { $0.status == .seeding }
            let port = try await seed.sessionStatus().listenPort
            scenarios.append(("loopback", nil))
            for (scenario, file) in scenarios {
                let state = root.appendingPathComponent("torrent-" + scenario)
                let downloads = root.appendingPathComponent("downloads-" + scenario)
                let liveSettings = TorrentEngineSettings(listenPort: 0, dht: scenario == "debian", lsd: false, portMapping: scenario == "debian")
                let engine = TorrentEngine(stateDirectory: state, binaryURL: binary, settings: liveSettings)
                let options = EngineOptions(downloadDirectory: downloads, downloadLimit: 256 * 1024)
                do {
                    try await engine.start(options: options)
                    var before: EngineTaskSnapshot?
                    if scenario == "loopback" {
                        let magnet = "magnet:?xt=urn:btih:\(seedID)&x.pe=127.0.0.1:\(port)"
                        let id = try await engine.add(link: .magnet(infoHash: seedID, displayName: nil, original: magnet), directory: nil)
                        before = try await waitFor(engine, id: id) { $0.receivedBytes >= 262_144 && $0.status == .downloading }
                    } else if let file {
                        let id = try await engine.add(link: .torrentFile(url: file, original: file.path), directory: nil)
                        before = try await waitFor(engine, id: id, timeout: .seconds(90)) {
                            $0.receivedBytes > 0 && $0.status == .downloading
                        }
                    }
                    await measure(engine, name: "torrentd", state: scenario, bytes: before?.receivedBytes ?? 0)
                    if let before {
                        let resume = state.appendingPathComponent("resume/\(before.engineTaskID).resume")
                        #expect(try Data(contentsOf: resume).count > 0)
                        // With the only seed paused, recovery cannot hide lost pieces
                        // by downloading them again before the assertion.
                        if scenario == "loopback" { try await seed.pause(seedID) }
                        try await engine.start(options: options)
                        let restored = try await waitFor(engine, id: before.engineTaskID) { $0.receivedBytes >= before.receivedBytes }
                        #expect(restored.receivedBytes >= before.receivedBytes)
                    }
                    await engine.stop()
                } catch {
                    await engine.stop()
                    throw error
                }
            }
            await seed.stop()
        } catch {
            await seed.stop()
            throw error
        }
    }

    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    private func measure(_ engine: any DownloadEngine, name: String, state: String, bytes: Int64) async {
        let start = ContinuousClock.now
        await engine.stop()
        let duration = start.duration(to: .now).components
        let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        print("SHUTDOWN_MEASUREMENT {\"engine\":\"\(name)\",\"state\":\"\(state)\",\"seconds\":\(seconds),\"bytes\":\(bytes)}")
    }

    private func waitFor(
        _ engine: TorrentEngine, id: String, timeout: Duration = .seconds(30),
        matching predicate: (EngineTaskSnapshot) -> Bool
    ) async throws -> EngineTaskSnapshot {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let snapshot = try await engine.snapshots().first(where: { $0.engineTaskID == id }), predicate(snapshot) {
                return snapshot
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw URLError(.timedOut)
    }
}
