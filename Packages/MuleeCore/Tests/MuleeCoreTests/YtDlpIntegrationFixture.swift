import Darwin
import Foundation
import Testing
@testable import MuleeCore

struct YtDlpIntegrationFixture: Sendable {
    let root: URL
    let engine: YtDlpEngine
    let server: Aria2HTTPServer
    let port: UInt16
    let payload: Data

    static let binary = URL(fileURLWithPath: "/opt/homebrew/bin/yt-dlp")
    static let ffmpeg = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
    static var available: Bool {
        FileManager.default.isExecutableFile(atPath: binary.path)
            && FileManager.default.isExecutableFile(atPath: ffmpeg.path)
    }

    var state: URL { root.appendingPathComponent("state") }
    var downloads: URL { root.appendingPathComponent("downloads") }
    var options: EngineOptions {
        EngineOptions(downloadDirectory: downloads, maxConcurrentDownloads: 1)
    }

    func makeEngine() -> YtDlpEngine {
        Self.makeEngine(state: state)
    }

    static func makeEngine(state: URL) -> YtDlpEngine {
        YtDlpEngine(
            stateDirectory: state, binaryURL: binary, installer: nil, ffmpegURL: ffmpeg,
            updatesEnabled: false
        )
    }

    static func withFixture(_ body: @Sendable (Self) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("YtDlp-live-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture.mp4")
        let generation = try await YtDlpProcess.capture(binary: ffmpeg, arguments: [
            "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100", "-t", "5",
            "-c:v", "libx264", "-preset", "ultrafast", "-crf", "18", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-movflags", "+faststart", file.path
        ])
        try #require(generation.status == 0, Comment(rawValue: generation.output))
        let payload = try Data(contentsOf: file)
        let server = try Aria2HTTPServer(payload: payload)
        let engine = makeEngine(state: root.appendingPathComponent("state"))
        do {
            let port = try await server.start()
            let fixture = Self(root: root, engine: engine, server: server, port: port, payload: payload)
            try await body(fixture)
            await engine.stop()
            await server.stop()
            try await server.checkFailure()
            try await checkNoProcesses(root: root)
        } catch {
            await engine.stop()
            await server.stop()
            try await checkNoProcesses(root: root)
            throw error
        }
    }


    static func checkNoProcesses(root: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", root.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        while process.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 1, Comment(rawValue: "残留进程：" + output))
    }

    func link(_ path: String = "slow-fixture.mp4") throws -> ParsedLink {
        let url = try #require(URL(string: "http://127.0.0.1:\(port)/\(path)"))
        return .video(url: url, site: .other, original: url.absoluteString)
    }

    static func waitFor(
        _ engine: YtDlpEngine, id: String, timeout: Duration = .seconds(30),
        matching predicate: @Sendable (EngineTaskSnapshot) -> Bool
    ) async throws -> EngineTaskSnapshot {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var last: EngineTaskSnapshot?
        while ContinuousClock.now < deadline {
            if let snapshot = try await engine.snapshots().first(where: { $0.id == id }) {
                last = snapshot
                if predicate(snapshot) { return snapshot }
                if snapshot.status == .failed {
                    throw EngineError.invalidResponse("意外下载失败：\(snapshot.errorMessage ?? "未知")")
                }
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw EngineError.invalidResponse("等待视频任务超时：\(String(describing: last))")
    }

    /// 只删除本测试明确移入废纸篓的文件，保留用户原有内容。
    static func removeTrashed(_ name: String) throws -> Bool {
        let trash = try FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let matches = try FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent == name }
        for match in matches { try FileManager.default.removeItem(at: match) }
        return !matches.isEmpty
    }
}
