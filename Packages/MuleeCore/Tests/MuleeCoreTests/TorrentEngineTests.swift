import Foundation
import Testing
@testable import MuleeCore

@Suite struct TorrentEngineTests {
    @Test("仅在辅助进程确认 resume 刷盘后缩短网络关闭等待", arguments: [true, false])
    func shutdownRequiresSavedAcknowledgement(saved: Bool) async throws {
        let fake = TorrentFakeTransport()
        await fake.setResult("shutdown", .object(saved ? ["saved": .bool(true)] : [:]))
        try await TorrentFixtures.withEngine(fake: fake) { engine, root in
            try await engine.start(options: EngineOptions(downloadDirectory: root))
            await engine.stop()
            let grace = try #require(await fake.finishGrace)
            if saved {
                #expect(grace == .milliseconds(1200))
                #expect(await fake.finishTerminationGrace == .zero)
            } else {
                #expect(grace > .seconds(5))
                #expect(await fake.finishTerminationGrace == .seconds(5))
            }
        }
    }

    @Test("按任务读取做种者与私有标记，缺失任务返回 not_found")
    func taskInfo() async throws {
        let fake = TorrentFakeTransport()
        try await TorrentFixtures.withEngine(fake: fake) { engine, root in
            try await engine.start(options: EngineOptions(downloadDirectory: root))
            await fake.setResult("list", .object(["torrents": .array([TorrentFixtures.task([
                "is_private": .bool(true)
            ])])]))
            let info = try await engine.taskInfo(TorrentFixtures.id)
            #expect(info.numPeers == 3)
            #expect(info.numSeeds == 2)
            #expect(info.listPeers == 10)
            #expect(info.listSeeds == 5)
            #expect(info.ratio == 0.5)
            #expect(info.isPrivate)
            #expect(info.hasMetadata)
            #expect(info.uploadLimit == 0)
            await #expect(throws: TorrentErrorDescriptions.error(for: "not_found")) {
                try await engine.taskInfo("missing")
            }
        }
    }

    @Test("BT 诊断解析、下载模式及 tracker API")
    func torrentControls() async throws {
        let fake = TorrentFakeTransport()
        try await TorrentFixtures.withEngine(fake: fake) { engine, root in
            var settings = TorrentEngineSettings()
            #expect(settings.diskCacheBytes == 16 * 1_024 * 1_024)
            #expect(settings.blockedClients.isEmpty)
            #expect(TorrentEngineSettings.defaultBlockedClients == ["-XL"])
            try await engine.start(options: EngineOptions(downloadDirectory: root))
            settings.diskCacheBytes = 64 * 1_024 * 1_024
            settings.blockedClients = TorrentEngineSettings.defaultBlockedClients
            try await engine.configure(settings)
            #expect(await fake.sent.last?.parameters["disk_cache_bytes"] == .integer(64 * 1_024 * 1_024))
            #expect(await fake.sent.last?.parameters["blocked_clients"] == .array([.string("-XL")]))
            try await engine.setDownloadMode(TorrentFixtures.id, sequentialDownload: true, firstLastPriority: true)
            #expect(await fake.sent.last?.parameters == [
                "id": .string(TorrentFixtures.id), "sequential_download": .bool(true), "first_last_priority": .bool(true)
            ])
            await fake.setResult("add_trackers", .object(["added": .integer(1), "total": .integer(2)]))
            let result = try await engine.addTrackers(TorrentFixtures.id, urls: ["https://tracker.invalid/announce"])
            #expect(result.added == 1 && result.total == 2)
            #expect(await fake.sent.last?.parameters["urls"] == .array([.string("https://tracker.invalid/announce")]))
            let diagnostics: TorrentdValue = .object([
                "connected_peers": .integer(2), "peer_sources": .object([
                    "tracker": .integer(1), "dht": .integer(1), "pex": .integer(1), "lsd": .integer(0), "incoming": .integer(1)
                ]),
                "ipv4": .integer(1), "ipv6": .integer(1), "tcp": .integer(1), "utp": .integer(1),
                "trackers_available": .integer(1), "trackers_failed": .integer(1), "trackers_pending": .integer(1),
                "last_tracker_error": .string("fixture error"), "disk_backlogged": .bool(true),
                "queued_disk_bytes": .integer(1_024), "disk_blocked_peers": .integer(1),
                "disk_queue_limit": .integer(1_024 * 1_024), "blocked_clients_count": .integer(3)
            ])
            await fake.setResult("list", .object(["torrents": .array([TorrentFixtures.task([
                "diagnostics": diagnostics, "sequential_download": .bool(true), "first_last_priority": .bool(true)
            ])])]))
            let info = try await engine.taskInfo(TorrentFixtures.id)
            #expect(info.isFinished && info.sequentialDownload && info.firstLastPriority)
            let sample = try #require(info.diagnostics)
            #expect(sample.connectedPeers == 2 && sample.peerSources.pex == 1 && sample.peerSources.incoming == 1)
            #expect(sample.ipv4 == 1 && sample.ipv6 == 1 && sample.tcp == 1 && sample.utp == 1)
            #expect(sample.trackersAvailable == 1 && sample.trackersFailed == 1 && sample.trackersPending == 1)
            #expect(sample.lastTrackerError == "fixture error")
            #expect(sample.diskBacklogged == true && sample.diskBlockedPeers == 1 && sample.queuedDiskBytes == 1_024)
            #expect(sample.diskQueueLimit == 1_024 * 1_024 && sample.blockedClientsCount == 3)
        }
    }

    @Test("下载中高分享率不暂停或降速，包括私有种子和恢复任务", arguments: [TorrentSeedingAction.stop, .slowDown])
    func downloadingRatio(_ policy: TorrentSeedingAction) async throws {
        let fake = TorrentFakeTransport()
        let settings = TorrentEngineSettings(seedingAction: policy, exemptPrivateTorrents: false)
        try await TorrentFixtures.withEngine(fake: fake, settings: settings) { engine, root in
            try await engine.start(options: EngineOptions(downloadDirectory: root))
            for state in ["downloading", "checking", "metadata"] {
                for isPrivate in [false, true] {
                    await fake.setResult("list", .object(["torrents": .array([TorrentFixtures.task([
                        "state": .string(state), "is_finished": .bool(false), "ratio": .double(2),
                        "is_private": .bool(isPrivate), "total_wanted_done": .integer(600)
                    ])])]))
                    _ = try await engine.snapshots()
                    #expect(await fake.sent.last?.method == "list")
                }
            }
            await fake.setResult("list", .object(["torrents": .array([TorrentFixtures.task([
                "ratio": .double(2), "is_private": .bool(true)
            ])])]))
            _ = try await engine.snapshots()
            #expect(await fake.sent.last?.method == (policy == .stop ? "pause" : "set_upload_limit"))
        }
    }

    @Test("ready 前不发请求，ready 超时回收进程")
    func readyTimeout() async throws {
        let fake = TorrentFakeTransport(sendsReady: false)
        try await TorrentFixtures.withEngine(fake: fake, readyTimeout: .milliseconds(20)) { engine, root in
            await #expect(throws: EngineError.launchFailed(String(localized: "等待 BT 引擎就绪超时", bundle: .module))) {
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
                "dht": .bool(false), "lsd": .bool(false), "port_mapping": .bool(false), "encryption": .string("require"),
                "disk_cache_bytes": .integer(16 * 1_024 * 1_024), "blocked_clients": .array([])
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

@Test("额外端口关闭时保留期望值，更新和清空会下发")
func extraPortMappingsLifecycle() async throws {
    let fake = TorrentFakeTransport()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let engine = TorrentEngine(stateDirectory: root, transportFactory: { fake })
    do {
        try await engine.start(options: EngineOptions(downloadDirectory: root))
        try await engine.setExtraPortMappings(ExtraPortMappings(tcp: [40123], udp: [40126, 40133]))
        try await engine.configure(TorrentEngineSettings(portMapping: false))
        try await engine.configure(TorrentEngineSettings(portMapping: true))
        let requests = await fake.sent.filter { $0.method == "set_extra_port_mappings" }
        #expect(requests.count == 3)
        #expect(requests.last?.parameters["tcp"] == .array([.integer(40123)]))
        try await engine.setExtraPortMappings(ExtraPortMappings())
        #expect(await fake.sent.last?.parameters["tcp"] == .array([]))
        await engine.stop()
        try FileManager.default.removeItem(at: root)
    } catch {
        await engine.stop()
        try? FileManager.default.removeItem(at: root)
        throw error
    }
}

@Test("任一映射机制成功即可，改写外部端口不能算就绪")
func extraMappingResultInterpretation() throws {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let json = """
        {"protocol":"tcp","local_port":40123,"results":[
            {"transport":"natpmp","external_port":0,"local_port":40123,
             "protocol":"tcp","succeeded":false,"message":"unavailable"},
            {"transport":"upnp","external_port":40123,"local_port":40123,
             "protocol":"tcp","succeeded":true,"message":""}
        ]}
        """
    #expect(try decoder.decode(ExtraPortMappingStatus.self, from: Data(json.utf8)).succeeded == true)
    let alternate = json.replacingOccurrences(of: "\"external_port\":40123", with: "\"external_port\":40124")
    #expect(try decoder.decode(ExtraPortMappingStatus.self, from: Data(alternate.utf8)).succeeded == false)
}
