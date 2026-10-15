import CryptoKit
import Darwin
import Foundation
import Testing
@testable import MuleeCore

struct Aria2IntegrationFixture: Sendable {
    let root: URL
    let state: URL
    let downloads: URL
    let engine: Aria2Engine
    let server: Aria2HTTPServer
    let port: UInt16
    let payload: Data

    static var binaryAvailable: Bool {
        (try? Aria2BinaryLocator.locate(explicitURL: nil)) != nil
    }

    static func withFixture(_ body: @Sendable (Self) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Aria2-live-\(UUID())")
        let state = root.appendingPathComponent("state")
        let downloads = root.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let engine = Aria2Engine(stateDirectory: state)
        var generator = SystemRandomNumberGenerator()
        let words = (0..<(4 * 1024 * 1024 / 8)).map { _ in
            UInt64.random(in: .min ... .max, using: &generator)
        }
        let payload = words.withUnsafeBytes { Data($0) }
        let server = try Aria2HTTPServer(payload: payload)
        do {
            let port = try await server.start()
            let fixture = Self(
                root: root, state: state, downloads: downloads,
                engine: engine, server: server, port: port, payload: payload
            )
            try await body(fixture)
            await engine.stop()
            await server.stop()
            try await server.checkFailure()
            #expect(try childProcessIDs().isEmpty)
            try FileManager.default.removeItem(at: root)
        } catch {
            await engine.stop()
            await server.stop()
            #expect(try childProcessIDs().isEmpty)
            try FileManager.default.removeItem(at: root)
            throw error
        }
    }

    var options: EngineOptions {
        EngineOptions(downloadDirectory: downloads, connectionsPerServer: 2, diskCacheMegabytes: 4)
    }

    func link(_ path: String) throws -> ParsedLink {
        let url = try #require(URL(string: "http://127.0.0.1:\(port)/\(path)"))
        return .http(url: url, decodedFromThunder: false, original: url.absoluteString)
    }

    func waitFor(
        _ id: String,
        timeout: Duration = .seconds(15),
        matching predicate: @Sendable (EngineTaskSnapshot) -> Bool
    ) async throws -> EngineTaskSnapshot {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var last: EngineTaskSnapshot?
        while ContinuousClock.now < deadline {
            if let snapshot = try await engine.snapshots().first(where: { $0.engineTaskID == id }) {
                last = snapshot
                if predicate(snapshot) { return snapshot }
                if snapshot.status == .failed {
                    throw EngineError.invalidResponse("意外下载失败：\(snapshot.errorMessage ?? "未知错误")")
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw EngineError.invalidResponse("等待状态超时：\(String(describing: last))")
    }

    func rpc() throws -> Aria2RPCClient {
        let values = try configurationValues()
        let port = try #require(values["rpc-listen-port"].flatMap(UInt16.init))
        return try Aria2RPCClient(port: port, secret: #require(values["rpc-secret"]))
    }

    func configurationValues() throws -> [String: String] {
        let text = try String(contentsOf: state.appendingPathComponent("aria2.conf"), encoding: .utf8)
        return Dictionary(uniqueKeysWithValues: text.split(separator: "\n").compactMap { line in
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { return nil }
            return (String(pair[0]), String(pair[1]))
        })
    }

    static func childProcessIDs() throws -> [Int32] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-P", String(getpid()), "-x", "aria2c"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard [0, 1].contains(process.terminationStatus) else {
            throw EngineError.invalidResponse("无法检查 aria2 子进程")
        }
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
    }
}
