import Darwin
import Foundation
import Testing
@testable import MuleeCore

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MULEE_TORRENTD"].map {
    FileManager.default.isExecutableFile(atPath: $0)
} ?? false))
struct TorrentIntegrationTests {
    @Test("真实 torrentd 启动、配置、本地种子做种自检和无残留退出")
    func seedAndStop() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["MULEE_TORRENTD"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mulee-torrent-integration-" + UUID().uuidString)
        let downloads = root.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let payload = Data("Ubuntu torrentd self-check\n".utf8)
        let torrent = TorrentFixtures.torrent(payload: payload)
        let torrentURL = root.appendingPathComponent("Ubuntu.torrent")
        try torrent.write(to: torrentURL)
        try payload.write(to: downloads.appendingPathComponent("Ubuntu.txt"))
        let info = try TorrentFileInfo.parse(data: torrent)
        let settings = TorrentEngineSettings(listenPort: 0, dht: false, lsd: false, portMapping: false)
        let engine = TorrentEngine(stateDirectory: root.appendingPathComponent("state"), binaryURL: URL(fileURLWithPath: path), settings: settings)
        do {
            try await engine.start(options: EngineOptions(downloadDirectory: downloads))
            try await engine.configure(settings)
            let session = try await engine.sessionStatus()
            #expect((1...65535).contains(session.listenPort))
            let children = try childProcessIDs()
            #expect(children.count == 1)
            let id = try await engine.add(link: .torrentFile(url: torrentURL, original: torrentURL.path), directory: downloads, filePriorities: [4])
            #expect(id == info.infoHash)
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            while true {
                let snapshot = try await engine.snapshots().first { $0.engineTaskID == id }
                if let snapshot, snapshot.status == .seeding {
                    #expect(snapshot.totalBytes == Int64(payload.count))
                    #expect(snapshot.receivedBytes == Int64(payload.count))
                    #expect(snapshot.savePath?.lastPathComponent == "Ubuntu.txt")
                    #expect(try await engine.files(id).count == 1)
                    break
                }
                guard ContinuousClock.now < deadline else { throw EngineError.launchFailed("做种自检超时") }
                try await Task.sleep(for: .milliseconds(50))
            }
            await engine.stop()
            for pid in children {
                #expect(kill(pid, 0) == -1)
                #expect(errno == ESRCH)
            }
            #expect(try childProcessIDs().isEmpty)
            await #expect(throws: EngineError.notRunning) { try await engine.snapshots() }
            try FileManager.default.removeItem(at: root)
        } catch {
            await engine.stop()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private func childProcessIDs() throws -> [pid_t] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-P", String(getpid()), "-x", "mulee-torrentd"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard [0, 1].contains(process.terminationStatus) else {
            throw EngineError.invalidResponse("无法检查 BT 引擎子进程")
        }
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace).compactMap { pid_t($0) }
    }
}
