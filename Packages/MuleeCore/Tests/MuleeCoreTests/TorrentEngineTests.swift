import Foundation
import Testing
@testable import MuleeCore

@Suite struct TorrentEngineTests {
    @Test(arguments: ["file_error: Input/output error", "io_error", "No such device"])
    func fileErrorsAreMarkedBeforeMessageCleaning(raw: String) async throws {
        let fake = TorrentFakeTransport()
        try await TorrentFixtures.withEngine(fake: fake) { engine, root in
            try await engine.start(options: EngineOptions(downloadDirectory: root))
            await fake.setResult("list", .object(["torrents": .array([
                TorrentFixtures.task(["state": .string("error"), "error": .string(raw)])
            ])]))
            #expect(try await engine.snapshots().first?.isFileWriteFailure == true)
        }
    }

    @Test("制作进度按 job_id 分发，取消 API 使用同一个 job_id")
    func creationProgress() async throws {
        let fake = TorrentFakeTransport()
        try await TorrentFixtures.withEngine(fake: fake) { engine, root in
            try await engine.start(options: EngineOptions(downloadDirectory: root))
            await fake.hold("create_torrent")
            let jobID = UUID()
            let (updates, continuation) = AsyncStream<TorrentCreationProgress>.makeStream()
            let creation = Task {
                try await engine.createTorrent(from: root, to: root.appending(path: "fixture.torrent"), jobID: jobID) {
                    continuation.yield($0)
                }
            }
            var requests = fake.requests.makeAsyncIterator()
            var create: TorrentTestRequest?
            while let request = await requests.next() {
                if request.method == "create_torrent" { create = request; break }
            }
            #expect(create?.parameters["job_id"] == .string(jobID.uuidString))
            let event = """
                {"event":"create_progress","job_id":"\(jobID.uuidString)","completed_pieces":2,
                 "total_pieces":4,"processed_bytes":512,"total_bytes":1024}
                """.replacingOccurrences(of: "\n", with: "")
            await fake.emit(Data((event + "\n").utf8))
            var progress = updates.makeAsyncIterator()
            #expect(await progress.next() == TorrentCreationProgress(
                completedPieces: 2, totalPieces: 4, processedBytes: 512, totalBytes: 1024
            ))
            try await engine.cancelCreate(jobID: jobID)
            #expect(await fake.sent.last?.method == "cancel_create")
            #expect(await fake.sent.last?.parameters["job_id"] == .string(jobID.uuidString))
            let request = try #require(create)
            let cancelled = TorrentdResponse(id: request.id, result: nil, error: TorrentdError(code: "cancelled", message: "cancelled"))
            await fake.emit(try JSONEncoder().encode(cancelled) + Data([10]))
            await #expect(throws: CancellationError.self) { try await creation.value }
            continuation.finish()
        }
    }

    @Test("单任务改名冲突映射为可读错误，其他快照正常返回")
    func isolatedSnapshotConflict() async throws {
        let fake = TorrentFakeTransport()
        try await TorrentFixtures.withEngine(fake: fake) { engine, root in
            try await engine.start(options: EngineOptions(downloadDirectory: root))
            await fake.setResult("list", .object(["torrents": .array([
                TorrentFixtures.task(["state": .string("error"), "error": .string("conflict"),
                                      "paused": .bool(true), "is_finished": .bool(false)]),
                TorrentFixtures.task(["id": .string("healthy-task")])
            ])]))
            let snapshots = try await engine.snapshots()
            #expect(snapshots.count == 2)
            let failed = try #require(snapshots.first { $0.engineTaskID == TorrentFixtures.id })
            #expect(failed.status == .failed)
            #expect(failed.errorMessage == String(localized: "文件改名遇到同名文件，暂时无法完成下载；请移走或重命名冲突文件后重试。", bundle: .module))
            #expect(snapshots.last?.status == .seeding)
        }
    }

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
                "is_private": .bool(true), "seed_time_seconds": .integer(120), "seed_inactive_seconds": .integer(20)
            ])])]))
            let info = try await engine.taskInfo(TorrentFixtures.id)
            #expect(info.numPeers == 3)
            #expect(info.numSeeds == 2)
            #expect(info.listPeers == 10)
            #expect(info.listSeeds == 5)
            #expect(info.ratio == 0.5)
            #expect(info.isPrivate)
            #expect(info.hasMetadata)
            #expect(info.seedTimeSeconds == 120 && info.seedInactiveSeconds == 20)
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

    @Test("管理 API 参数、状态解析、过滤反馈和错误映射")
    func managementAPIs() async throws {
        let fake = TorrentFakeTransport()
        try await TorrentFixtures.withEngine(fake: fake) { engine, root in
            try await engine.start(options: EngineOptions(downloadDirectory: root))
            var settings = TorrentEngineSettings()
            settings.skipJunkFiles = false
            settings.junkFilePatterns = ["*.url"]
            settings.ipBlocklistPath = "/tmp/test.dat"
            try await engine.configure(settings)
            #expect(await fake.sent.last?.parameters["skip_junk_files"] == .bool(false))
            #expect(await fake.sent.last?.parameters["junk_file_patterns"] == .array([.string("*.url")]))
            #expect(await fake.sent.last?.parameters["ip_blocklist_path"] == .string("/tmp/test.dat"))
            await fake.setResult("add", .object([
                "id": .string(TorrentFixtures.id), "name": .string("Fixture"), "duplicate": .bool(false),
                "skipped_files": .array([.object(["index": .integer(1), "path": .string("Fixture/ad.url")])])
            ]))
            let added = try await engine.addWithResult(link: TorrentFixtures.magnet, directory: root)
            #expect(added.skippedFiles?.first?.path == "Fixture/ad.url")
            try await engine.moveStorage(added.id, to: root, conflict: .keep)
            #expect(await fake.sent.last?.parameters["conflict"] == .string("keep"))
            await fake.setError("move_storage", code: "conflict")
            await #expect(throws: TorrentErrorDescriptions.error(for: "conflict")) {
                try await engine.moveStorage(added.id, to: root)
            }
            try await engine.renameFile(added.id, path: "Fixture", to: "Renamed")
            #expect(await fake.sent.last?.parameters["new_path"] == .string("Renamed"))
            try await engine.forceRecheck(added.id)
            #expect(await fake.sent.last?.method == "force_recheck")
            try await engine.forceReannounce(added.id)
            #expect(await fake.sent.last?.method == "force_reannounce")
            let tracker = TorrentTracker(url: "https://tracker.invalid/announce", tier: 3, subscription: true)
            try await engine.setTrackers(added.id, trackers: [tracker])
            #expect(await fake.sent.last?.parameters["trackers"] == .array([.object([
                "url": .string(tracker.url), "tier": .integer(3), "subscription": .bool(true)
            ])]))
            await fake.setResult("trackers", .object(["trackers": .array([.object([
                "url": .string(tracker.url), "tier": .integer(3), "subscription": .bool(true),
                "status": .string("disabled"), "last_result": .string("timeout"), "peers": .integer(0), "disabled_until": .integer(1000)
            ])])]))
            #expect(try await engine.trackers(added.id).first?.disabledUntil == 1000)
            await fake.setResult("peers", .object(["peers": .array([.object([
                "address": .string("192.0.2.10"), "port": .integer(6881), "client": .string("Mulee"),
                "progress": .double(0.5), "download_rate": .integer(123), "upload_rate": .integer(45),
                "sources": .array([.string("tracker"), .string("pex")]), "connection": .string("utp")
            ])])]))
            let peer = try #require(try await engine.peers(added.id).first)
            #expect(peer.connection == "utp" && peer.sources == ["tracker", "pex"] && peer.downloadRate == 123)
            try await engine.banIP(peer.address)
            #expect(await fake.sent.last?.parameters["ip"] == .string("192.0.2.10"))
            await fake.setResult("import_ip_blocklist", .object(["blocked_ranges": .integer(2)]))
            #expect(try await engine.importIPBlocklist(from: root).blockedRanges == 2)
            let output = root.appending(path: "fixture.torrent")
            for method in ["create_torrent", "export_torrent"] {
                await fake.setResult(method, .object(["path": .string(output.path), "id": .string(added.id)]))
            }
            #expect(try await engine.createTorrent(from: root, to: output, isPrivate: true, trackers: [tracker.url], comment: "Fixture").id == added.id)
            #expect(await fake.sent.last?.parameters["private"] == .bool(true))
            #expect(await fake.sent.last?.parameters["comment"] == .string("Fixture"))
            #expect(try await engine.exportTorrent(added.id, to: output).path == output.path)
        }
    }

    @Test("手填公共 tracker 与订阅来源分别下发")
    func trackerProvenance() async throws {
        let fake = TorrentFakeTransport()
        try await TorrentFixtures.withEngine(fake: fake) { engine, root in
            try await engine.start(options: EngineOptions(downloadDirectory: root))
            let manual = "https://manual.invalid/announce"
            let subscribed = "https://subscription.invalid/announce"
            await engine.configurePublicTrackers([manual, subscribed], subscriptionURLs: [subscribed])
            await fake.setResult("list", .object(["torrents": .array([TorrentFixtures.task()])]))
            await fake.setResult("add_trackers", .object(["added": .integer(1), "total": .integer(2)]))
            _ = try await engine.snapshots()
            let additions = await fake.sent.filter { $0.method == "add_trackers" }
            #expect(additions.count == 2)
            #expect(additions.first?.parameters["subscription"] == .bool(false))
            #expect(additions.last?.parameters["subscription"] == .bool(true))
        }
    }

    @Test("时间策略删除任务保留文件，未完成时不会删除")
    func timedRemoval() async throws {
        let fake = TorrentFakeTransport()
        let settings = TorrentEngineSettings(seedingAction: .remove, seedTimeLimitMinutes: 1)
        try await TorrentFixtures.withEngine(fake: fake, settings: settings) { engine, root in
            try await engine.start(options: EngineOptions(downloadDirectory: root))
            await fake.setResult("list", .object(["torrents": .array([TorrentFixtures.task([
                "seed_time_seconds": .integer(60), "ratio": .double(0.1)
            ])])]))
            #expect(try await engine.snapshots().isEmpty)
            #expect(await fake.sent.last?.method == "remove")
            #expect(await fake.sent.last?.parameters["delete_files"] == .bool(false))
            #expect(await engine.consumePolicyRemovals() == [TorrentFixtures.id])
            #expect(await engine.consumePolicyRemovals().isEmpty)
            await fake.setResult("list", .object(["torrents": .array([TorrentFixtures.task([
                "seed_time_seconds": .integer(600), "state": .string("checking"), "ratio": .double(2)
            ])])]))
            _ = try await engine.snapshots()
            #expect(await fake.sent.last?.method == "list")
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
                "disk_cache_bytes": .integer(16 * 1_024 * 1_024), "blocked_clients": .array([]),
                "skip_junk_files": .bool(true),
                "junk_file_patterns": .array(TorrentEngineSettings.defaultJunkFilePatterns.map(TorrentdValue.string)),
                "ip_blocklist_path": .string(""), "ip_blocklist_url_path": .string("")
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
