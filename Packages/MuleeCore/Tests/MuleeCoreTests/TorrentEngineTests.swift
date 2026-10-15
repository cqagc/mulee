import Foundation
import Testing
@testable import MuleeCore

@Suite struct TorrentEngineTests {
    @Test("ready 前不发请求，ready 超时回收进程")
    func readyTimeout() async throws {
        let fake = TorrentFakeTransport(sendsReady: false)
        try await TorrentFixtures.withEngine(fake: fake, readyTimeout: .milliseconds(20)) { engine, root in
            await #expect(throws: EngineError.launchFailed("等待 BT 引擎就绪超时")) {
                try await engine.start(options: EngineOptions(downloadDirectory: root))
            }
            #expect(await fake.sent.isEmpty)
            #expect(await fake.finishCount == 1)
            await #expect(throws: EngineError.notRunning) { try await engine.snapshots() }
        }
    }

    @Test("完整 configure 参数、运行时设置与 EngineOptions 合并")
    func configure() async throws {
        let fake = TorrentFakeTransport()
        let settings = TorrentEngineSettings(
            listenPort: 12345, dht: false, lsd: false, portMapping: false,
            encryption: .require, maxActiveSeeds: 7, seedingAction: .slowDown, exemptPrivateTorrents: false
        )
        try await TorrentFixtures.withEngine(fake: fake, settings: settings) { engine, root in
            var options = EngineOptions(downloadDirectory: root, maxConcurrentDownloads: 3, downloadLimit: 1234, uploadLimit: 5678)
            try await engine.start(options: options)
            try await engine.start(options: options)
            #expect(await fake.startCount == 1)
            let first = try #require(await fake.sent.first)
            #expect(first.method == "configure")
            #expect(first.parameters == [
                "download_dir": .string(root.path), "listen_port": .integer(12345),
                "download_limit": .integer(1234), "upload_limit": .integer(5678),
                "max_active_downloads": .integer(3), "max_active_seeds": .integer(7),
                "dht": .bool(false), "lsd": .bool(false), "port_mapping": .bool(false), "encryption": .string("require")
            ])
            options.uploadLimit = 999
            try await engine.apply(options: options)
            var changed = settings
            changed.listenPort = 0
            changed.encryption = .disable
            try await engine.configure(changed)
            let last = try #require(await fake.sent.last)
            #expect(last.parameters["listen_port"] == .integer(0))
            #expect(last.parameters["upload_limit"] == .integer(999))
            #expect(last.parameters["encryption"] == .string("disable"))
            await engine.stop()
            #expect(await fake.sent.last?.method == "shutdown")
            #expect(!(await fake.isRunning()))
        }
    }

    @Test("add、文件列表、优先级、会话和 remove 参数")
    func publicOperations() async throws {
        let fake = TorrentFakeTransport()
        try await TorrentFixtures.withEngine(fake: fake) { engine, root in
            try await engine.start(options: EngineOptions(downloadDirectory: root))
            #expect(try await engine.add(link: TorrentFixtures.magnet, directory: root) == TorrentFixtures.id)
            let magnet = try #require(await fake.sent.last)
            #expect(magnet.parameters["magnet"] == .string(TorrentFixtures.magnet.original))
            #expect(magnet.parameters["source"] == .string(TorrentFixtures.magnet.original))
            #expect(magnet.parameters["save_path"] == .string(root.path))
            let file = root.appendingPathComponent("Ubuntu.torrent")
            let data = TorrentFixtures.torrent(payload: Data("Ubuntu".utf8))
            try data.write(to: file)
            _ = try await engine.add(link: .torrentFile(url: file, original: file.path), directory: nil, filePriorities: [4])
            #expect(await fake.addedTorrent == data)
            #expect(await fake.sent.last?.parameters["file_priorities"] == .array([.integer(4)]))
            #expect(FileManager.default.fileExists(atPath: file.path))
            await fake.setResult("files", .object(["files": .array([.object([
                "index": .integer(0), "path": .string("Ubuntu.txt"), "size": .integer(6), "done": .integer(3), "priority": .integer(4)
            ])])]))
            #expect(try await engine.files(TorrentFixtures.id) == [TorrentFileEntry(index: 0, path: "Ubuntu.txt", size: 6, done: 3)])
            try await engine.setFilePriorities(TorrentFixtures.id, [0, 4])
            #expect(await fake.sent.last?.parameters["priorities"] == .array([.integer(0), .integer(4)]))
            let session = try await engine.sessionStatus()
            #expect(session.listenPort == 6881)
            #expect(session.dhtNodes == 42)
            #expect(session.hasIncomingConnections)
            #expect(session.downloadRate == 123)
            #expect(session.uploadRate == 456)
            #expect(session.externalAddress == nil)
            try await engine.pause(TorrentFixtures.id)
            #expect(await fake.sent.last?.method == "pause")
            try await engine.resume(TorrentFixtures.id)
            #expect(await fake.sent.last?.method == "resume")
            try await engine.remove(TorrentFixtures.id, deleteFiles: true)
            #expect(await fake.sent.last?.parameters == ["id": .string(TorrentFixtures.id), "delete_files": .bool(true)])
            let unsupported = ParsedLink.http(url: root, decodedFromThunder: false, original: root.path)
            await #expect(throws: EngineError.unsupportedLink) { try await engine.add(link: unsupported, directory: nil) }
        }
    }

    @Test("snapshots 返回 BT 详情，策略降速后不重复发送命令")
    func snapshotsAndPolicy() async throws {
        let fake = TorrentFakeTransport()
        try await TorrentFixtures.withEngine(fake: fake, settings: TorrentEngineSettings(seedingAction: .slowDown)) { engine, root in
            try await engine.start(options: EngineOptions(downloadDirectory: root))
            await fake.setResult("list", .object(["torrents": .array([TorrentFixtures.task(["ratio": .double(1)])])]))
            let snapshot = try #require(try await engine.snapshots().first)
            #expect(snapshot.detail == .bittorrent(fileCount: 4, selectedFileCount: 2, peerCount: 3, shareRatio: 1))
            #expect(snapshot.savePath?.path == "/tmp/downloads/Ubuntu")
            #expect(snapshot.completedAt == Date(timeIntervalSince1970: 200))
            #expect(await fake.sent.last?.method == "set_upload_limit")
            #expect(await fake.sent.last?.parameters["limit"] == .integer(51_200))
            await fake.setResult("list", .object(["torrents": .array([TorrentFixtures.task([
                "ratio": .double(1), "upload_limit": .integer(51_200)
            ])])]))
            _ = try await engine.snapshots()
            #expect(await fake.sent.filter { $0.method == "set_upload_limit" }.count == 1)
            try await engine.configure(TorrentEngineSettings(seedingAction: .stop))
            _ = try await engine.snapshots()
            #expect(await fake.sent.last?.method == "pause")
            await fake.setResult("list", .object(["torrents": .array([TorrentFixtures.task([
                "ratio": .double(1), "paused": .bool(true), "state": .string("finished")
            ])])]))
            _ = try await engine.snapshots()
            #expect(await fake.sent.filter { $0.method == "pause" }.count == 1)
            await fake.setResult("list", .object(["torrents": .array([TorrentFixtures.task([
                "ratio": .double(2), "is_private": .bool(true)
            ])])]))
            _ = try await engine.snapshots()
            #expect(await fake.sent.filter { $0.method == "pause" }.count == 1)
        }
    }
}
