import Foundation
import OSLog

/// BT / 磁力下载引擎，通过 JSON Lines 控制独立的 mulee-torrentd 进程。
public actor TorrentEngine: DownloadEngine {
    public nonisolated let kind: TaskKind = .bittorrent

    private let stateDirectory: URL
    private let binaryURL: URL?
    private let transportFactory: (@Sendable () -> any TorrentdTransport)?
    private let session: URLSession
    private let readyTimeout: Duration
    private let requestTimeout: Duration
    private let restartBackoff: Duration
    private var publicTrackers: [String] = []
    private var subscribedPublicTrackers = Set<String>()
    private var trackerRevision = UUID()
    private var policyRemovals = Set<String>()
    private var trackerDeliveries: [String: UUID] = [:]
    private var extraPortMappings = ExtraPortMappings()
    private var settings: TorrentEngineSettings
    private var options: EngineOptions?
    private var client: TorrentdClient?
    private var sessionID: UUID?
    private var monitor: Task<Void, Never>?
    private var starting: Task<Void, any Error>?
    private var stopping: Task<Void, Never>?
    private var restarting: Task<Void, Never>?
    private var restartUsed = false
    private var shouldRun = false
    private static let logger = Logger(subsystem: "MuleeCore", category: "Torrent")

    /// stateDirectory 由 App 传入 ~/Library/Application Support/Mulee/torrent。
    /// binaryURL 为 nil 时依次寻找 App 包内 Helpers 和 MULEE_TORRENTD。
    public init(
        stateDirectory: URL,
        binaryURL: URL? = nil,
        settings: TorrentEngineSettings = TorrentEngineSettings()
    ) {
        self.stateDirectory = stateDirectory
        self.binaryURL = binaryURL
        self.settings = settings
        transportFactory = nil
        session = URLSession(configuration: .ephemeral)
        readyTimeout = .seconds(15)
        requestTimeout = .seconds(10)
        restartBackoff = .seconds(1)
    }

    /// 测试注入；不依赖真实辅助程序，也不暴露测试传输给 App。
    init(
        stateDirectory: URL,
        settings: TorrentEngineSettings = TorrentEngineSettings(),
        readyTimeout: Duration = .seconds(15),
        requestTimeout: Duration = .seconds(10),
        restartBackoff: Duration = .seconds(1),
        session: URLSession = URLSession(configuration: .ephemeral),
        transportFactory: @escaping @Sendable () -> any TorrentdTransport
    ) {
        self.stateDirectory = stateDirectory
        binaryURL = nil
        self.settings = settings
        self.readyTimeout = readyTimeout
        self.requestTimeout = requestTimeout
        self.restartBackoff = restartBackoff
        self.session = session
        self.transportFactory = transportFactory
    }

    public func start(options: EngineOptions) async throws {
        if let stopping { await stopping.value }
        if let starting { return try await starting.value }
        if let client, await client.isRunning() { return }
        if let restarting {
            restarting.cancel()
            await restarting.value
            self.restarting = nil
        }
        if let client, await client.isRunning() { return }
        if let client {
            monitor?.cancel()
            sessionID = nil
            self.client = nil
            await client.finish(grace: .zero)
        }
        restartUsed = false
        shouldRun = true
        let task = Task { try await launch(options: options) }
        starting = task
        defer { starting = nil }
        do { try await task.value } catch {
            shouldRun = false
            throw error
        }
    }

    public func stop() async {
        if let stopping { return await stopping.value }
        shouldRun = false
        restarting?.cancel()
        let restart = restarting
        restarting = nil
        let task = Task {
            if let restart { await restart.value }
            if let starting {
                do { try await starting.value } catch {
                    Self.logger.debug("停止前 BT 引擎未能启动")
                }
            }
            await shutdown()
            // 退出通知可能在等待启动任务时到达，stop 也要等待它安排的回收。
            if let cleanup = restarting {
                cleanup.cancel()
                await cleanup.value
                restarting = nil
            }
        }
        stopping = task
        await task.value
        stopping = nil
    }

    public func apply(options: EngineOptions) async throws {
        let client = try await runningClient()
        try await sendConfiguration(options: options, settings: settings, using: client)
        self.options = options
    }

    public func configure(_ settings: TorrentEngineSettings) async throws {
        let client = try await runningClient()
        guard let options else { throw EngineError.notRunning }
        try await sendConfiguration(options: options, settings: settings, using: client)
        self.settings = settings
    }

    /// 保留期望值，辅助进程尚未启动或重启后也会重新下发。
    public func setExtraPortMappings(_ mappings: ExtraPortMappings) async throws {
        extraPortMappings = mappings
        // 启动期间的变更在会话发布后再确认一次，避免落在最后一次下发与发布之间。
        if let starting { try await starting.value }
        guard let client, await client.isRunning() else { return }
        let _: TorrentdEmpty = try await client.call("set_extra_port_mappings", extraPortMappings)
    }

    public func add(link: ParsedLink, directory: URL?) async throws -> String {
        try await add(link: link, directory: directory, filePriorities: nil)
    }

    public func addQueued(link: ParsedLink, directory: URL?) async throws -> String {
        try await add(link: link, directory: directory, filePriorities: nil, paused: true)
    }

    public func add(link: ParsedLink, directory: URL?, filePriorities: [Int]?, paused: Bool = false, markIncomplete: Bool = true) async throws -> String {
        try await addWithResult(link: link, directory: directory, filePriorities: filePriorities, paused: paused, markIncomplete: markIncomplete).id
    }

    /// 添加任务并返回垃圾文件过滤结果；显式 filePriorities 优先于自动过滤。
    public func addWithResult(
        link: ParsedLink, directory: URL?, filePriorities: [Int]? = nil, paused: Bool = false, markIncomplete: Bool = true
    ) async throws -> TorrentdAddResult {
        let client = try await runningClient()
        var params = TorrentdAddParameters(savePath: directory?.path, paused: paused, markIncomplete: markIncomplete, source: link.original)
        var temporary: URL?
        defer {
            if let temporary {
                do { try FileManager.default.removeItem(at: temporary) } catch {
                    Self.logger.warning("无法清理临时种子文件")
                }
            }
        }
        switch link {
        case .magnet(let hash, _, let original):
            guard filePriorities == nil else { throw TorrentErrorDescriptions.error(for: "invalid_params") }
            let decoded = ThunderLinkDecoder.decode(original) ?? original
            params.magnet = decoded.lowercased().hasPrefix("magnet:?") ? decoded : "magnet:?xt=urn:btih:\(hash)"
        case .torrentFile(let url, _):
            let file: URL
            if url.isFileURL {
                file = url
            } else {
                file = try await TorrentFileDownloader(session: session).download(
                    url, into: stateDirectory.appendingPathComponent("incoming", isDirectory: true)
                )
                temporary = file
            }
            params.torrentFile = file.path
            params.filePriorities = filePriorities
        default:
            throw EngineError.unsupportedLink
        }
        let result: TorrentdAddResult = try await client.call("add", params)
        if !result.duplicate {
            trackerDeliveries[result.id] = nil
            policyRemovals.remove(result.id)
        }
        return result
    }

    public func pause(_ engineTaskID: String) async throws {
        let client = try await runningClient()
        let _: TorrentdEmpty = try await client.call("pause", TorrentdIDParameters(id: engineTaskID))
    }

    public func resume(_ engineTaskID: String) async throws {
        let client = try await runningClient()
        let _: TorrentdEmpty = try await client.call("resume", TorrentdIDParameters(id: engineTaskID))
    }

    public func remove(_ engineTaskID: String, deleteFiles: Bool) async throws {
        let client = try await runningClient()
        let _: TorrentdEmpty = try await client.call(
            "remove", TorrentdRemoveParameters(id: engineTaskID, deleteFiles: deleteFiles)
        )
        trackerDeliveries[engineTaskID] = nil
    }

    public func taskInfo(_ id: String) async throws -> TorrentTaskInfo {
        let client = try await runningClient()
        let result: TorrentdListResult = try await client.call("list", TorrentdEmpty())
        guard let task = result.torrents.first(where: { $0.id == id }) else {
            throw TorrentErrorDescriptions.error(for: "not_found")
        }
        return TorrentTaskInfo(
            numPeers: task.numPeers, numSeeds: task.numSeeds,
            listPeers: task.listPeers, listSeeds: task.listSeeds,
            ratio: task.ratio, isPrivate: task.isPrivate,
            uploadLimit: task.uploadLimit, hasMetadata: task.hasMetadata,
            isFinished: task.canApplySeedingPolicy,
            sequentialDownload: task.sequentialDownload ?? false,
            firstLastPriority: task.firstLastPriority ?? false, diagnostics: task.diagnostics,
            seedTimeSeconds: task.seedTimeSeconds ?? 0, seedInactiveSeconds: task.seedInactiveSeconds ?? 0
        )
    }

    public func files(_ id: String) async throws -> [TorrentFileEntry] {
        let client = try await runningClient()
        let result: TorrentdFilesResult = try await client.call("files", TorrentdIDParameters(id: id))
        return result.files
    }

    public func setFilePriorities(_ id: String, _ priorities: [Int]) async throws {
        let client = try await runningClient()
        let _: TorrentdEmpty = try await client.call(
            "set_file_priorities", TorrentdPrioritiesParameters(id: id, priorities: priorities)
        )
    }

    /// 开关顺序下载和所选文件首尾 piece 优先；两个开关均持久化，默认关闭。
    public func setDownloadMode(_ id: String, sequentialDownload: Bool, firstLastPriority: Bool) async throws {
        let client = try await runningClient()
        let _: TorrentdEmpty = try await client.call(
            "set_download_mode", TorrentdDownloadModeParameters(
                id: id, sequentialDownload: sequentialDownload, firstLastPriority: firstLastPriority
            )
        )
    }

    /// 对指定文件开启顺序下载及首尾各 2% 的块优先；取消或完成时关闭。
    public func setStreaming(_ id: String, fileIndex: Int, enabled: Bool) async throws {
        let client = try await runningClient()
        let _: TorrentdEmpty = try await client.call(
            "set_streaming", TorrentdStreamingParameters(id: id, fileIndex: fileIndex, enabled: enabled)
        )
    }

    /// 去重追加 tracker；元数据未就绪、私有种子或超过数量上限时抛出明确错误。
    public func addTrackers(_ id: String, urls: [String]) async throws -> TorrentTrackerAdditionResult {
        let client = try await runningClient()
        return try await client.call("add_trackers", TorrentdTrackersParameters(id: id, urls: urls))
    }

    /// 等待存储移动完成；fail 遇到同名文件时返回 conflict 错误。
    public func moveStorage(_ id: String, to directory: URL, conflict: TorrentStorageConflict = .fail) async throws {
        let client = try await runningClient()
        let _: TorrentdEmpty = try await client.call(
            "move_storage", TorrentdMoveParameters(id: id, path: directory.path, conflict: conflict), timeout: .seconds(310)
        )
    }

    /// 重命名一个相对文件路径或整个目录前缀，等待磁盘操作完成。
    public func renameFile(_ id: String, path: String, to newPath: String) async throws {
        let client = try await runningClient()
        let _: TorrentdEmpty = try await client.call(
            "rename_file", TorrentdRenameParameters(id: id, path: path, newPath: newPath), timeout: .seconds(310)
        )
    }

    /// 重新校验所存数据。
    public func forceRecheck(_ id: String) async throws {
        let client = try await runningClient()
        let _: TorrentdEmpty = try await client.call("force_recheck", TorrentdIDParameters(id: id))
    }

    /// 立即向 tracker 重新宣告。
    public func forceReannounce(_ id: String) async throws {
        let client = try await runningClient()
        let _: TorrentdEmpty = try await client.call("force_reannounce", TorrentdIDParameters(id: id))
    }

    /// 包含自动停用条目的 tracker 状态。
    public func trackers(_ id: String) async throws -> [TorrentTrackerStatus] {
        let client = try await runningClient()
        let result: TorrentdTrackerList = try await client.call("trackers", TorrentdIDParameters(id: id))
        return result.trackers
    }

    /// 完整替换 tracker 列表，支持添加、编辑和删除；保留未编辑订阅条目的停用期。
    public func setTrackers(_ id: String, trackers: [TorrentTracker]) async throws {
        let client = try await runningClient()
        let _: TorrentdEmpty = try await client.call("set_trackers", TorrentdSetTrackersParameters(id: id, trackers: trackers))
    }

    /// 返回当前连接的节点列表。
    public func peers(_ id: String) async throws -> [TorrentPeer] {
        let client = try await runningClient()
        let result: TorrentdPeerList = try await client.call("peers", TorrentdIDParameters(id: id))
        return result.peers
    }

    /// 持久封禁一个 IPv4 或 IPv6 地址。
    public func banIP(_ address: String) async throws {
        let client = try await runningClient()
        let _: TorrentdEmpty = try await client.call("ban_ip", TorrentdBanParameters(ip: address))
    }

    /// 导入 P2P / DAT 黑名单，保留用户手动封禁的 IP。
    public func importIPBlocklist(from file: URL) async throws -> TorrentBlocklistResult {
        let client = try await runningClient()
        return try await client.call("import_ip_blocklist", TorrentdPathParameters(path: file.path))
    }

    /// 从文件或目录制作分块大小自动选择的 v1+v2 混合种子。
    public func createTorrent(
        from source: URL, to output: URL, isPrivate: Bool = false, trackers: [String] = [], comment: String? = nil
    ) async throws -> TorrentFileResult {
        let client = try await runningClient()
        return try await client.call("create_torrent", TorrentdCreateParameters(
            path: source.path, output: output.path, private: isPrivate, trackers: trackers, comment: comment
        ), timeout: .seconds(3600))
    }

    /// 导出保留原始 info hash 的种子；磁力任务必须先获取元数据。
    public func exportTorrent(_ id: String, to output: URL) async throws -> TorrentFileResult {
        let client = try await runningClient()
        return try await client.call("export_torrent", TorrentdExportParameters(id: id, output: output.path), timeout: .seconds(30))
    }

    /// 返回磁力取得元数据后自动跳过的文件，也适用于本地种子。
    public func skippedFiles(_ id: String) async throws -> [TorrentSkippedFile] {
        let client = try await runningClient()
        let result: TorrentdListResult = try await client.call("list", TorrentdEmpty())
        guard let task = result.torrents.first(where: { $0.id == id }) else {
            throw TorrentErrorDescriptions.error(for: "not_found")
        }
        return task.skippedFiles ?? []
    }

    public func sessionStatus() async throws -> TorrentSessionStatus {
        let client = try await runningClient()
        return try await client.call("session_status", TorrentdEmpty())
    }

    /// 空列表关闭自动追加；更改列表或重新开启后，现有公共任务也会重新检查。
    public func configurePublicTrackers(_ urls: [String], subscriptionURLs: [String]? = nil) {
        let validated = Array(PublicTrackerList.parse(urls.joined(separator: "\n")).prefix(50))
        let subscribed = Set(PublicTrackerList.parse((subscriptionURLs ?? urls).joined(separator: "\n"))).intersection(validated)
        guard validated != publicTrackers || subscribed != subscribedPublicTrackers else { return }
        publicTrackers = validated
        subscribedPublicTrackers = subscribed
        trackerRevision = UUID()
        trackerDeliveries.removeAll()
    }

    public func snapshots() async throws -> [EngineTaskSnapshot] {
        let client = try await runningClient()
        let result: TorrentdListResult = try await client.call("list", TorrentdEmpty())
        var removedIDs = Set<String>()
        for torrent in result.torrents {
            let action = SeedingPolicy.action(
                ratio: torrent.ratio, isFinished: torrent.canApplySeedingPolicy, isPrivate: torrent.isPrivate,
                paused: torrent.paused, uploadLimit: torrent.uploadLimit, settings: settings,
                seedTimeSeconds: torrent.seedTimeSeconds ?? 0, seedInactiveSeconds: torrent.seedInactiveSeconds ?? 0
            )
            switch action {
            case .none: break
            case .remove:
                try await remove(torrent.id, deleteFiles: false)
                removedIDs.insert(torrent.id)
                policyRemovals.insert(torrent.id)
            case .pause:
                let _: TorrentdEmpty = try await client.call("pause", TorrentdIDParameters(id: torrent.id))
            case .setUploadLimit(let limit):
                let _: TorrentdEmpty = try await client.call(
                    "set_upload_limit", TorrentdUploadLimitParameters(id: torrent.id, limit: limit)
                )
            }
        }
        let currentIDs = Set(result.torrents.map(\.id))
        trackerDeliveries = trackerDeliveries.filter { currentIDs.contains($0.key) }
        for torrent in result.torrents where torrent.hasMetadata && !torrent.isPrivate && !removedIDs.contains(torrent.id) {
            await appendPublicTrackers(to: torrent.id, using: client)
        }
        return result.torrents.filter { !removedIDs.contains($0.id) }.map(TorrentStatusMapper.snapshot)
    }

    /// 取走本会话由做种策略删除的任务标识，供 App 同步移除历史记录。
    public func consumePolicyRemovals() -> Set<String> {
        let removed = policyRemovals
        policyRemovals.removeAll()
        return removed
    }

    private func appendPublicTrackers(to id: String, using rpc: TorrentdClient) async {
        guard !publicTrackers.isEmpty, trackerDeliveries[id] != trackerRevision,
              let session = sessionID, client === rpc else { return }
        let revision = trackerRevision
        trackerDeliveries[id] = revision
        var remaining = publicTrackers
        var count = remaining.count
        while count > 0, trackerRevision == revision, sessionID == session, !Task.isCancelled {
            let subscription = subscribedPublicTrackers.contains(remaining[0])
            count = min(count, remaining.prefix { subscribedPublicTrackers.contains($0) == subscription }.count)
            do {
                let result: TorrentTrackerAdditionResult = try await rpc.call(
                    "add_trackers", TorrentdTrackersParameters(id: id, urls: Array(remaining.prefix(count)), subscription: subscription)
                )
                remaining.removeFirst(count)
                count = min(remaining.count, max(0, 50 - result.total))
            } catch EngineError.rpc(code: 10, message: _) {
                // Helper rejects the whole batch at its total limit; reduce until a batch fits.
                count /= 2
            } catch EngineError.rpc(code: 9, message: _) {
                // Metadata may have changed after list; helper remains the final privacy guard.
                return
            } catch {
                if trackerRevision == revision, sessionID == session { trackerDeliveries[id] = nil }
                return
            }
        }
        if Task.isCancelled, trackerRevision == revision, sessionID == session { trackerDeliveries[id] = nil }
    }

    private func runningClient() async throws -> TorrentdClient {
        guard stopping == nil, starting == nil, let client, await client.isRunning() else {
            throw EngineError.notRunning
        }
        return client
    }

    private func sendConfiguration(
        options: EngineOptions, settings: TorrentEngineSettings, using client: TorrentdClient
    ) async throws {
        let _: TorrentdConfigureResult = try await client.call(
            "configure", TorrentdConfigureParameters(options: options, settings: settings)
        )
        if !extraPortMappings.tcp.isEmpty || !extraPortMappings.udp.isEmpty {
            let _: TorrentdEmpty = try await client.call("set_extra_port_mappings", extraPortMappings)
        }
    }

    private func launch(options: EngineOptions) async throws {
        let transport: any TorrentdTransport
        if let transportFactory {
            transport = transportFactory()
        } else {
            transport = TorrentdProcessTransport(
                binary: try TorrentBinaryLocator.locate(explicitURL: binaryURL), stateDirectory: stateDirectory
            )
        }
        do {
            try FileManager.default.createDirectory(
                at: stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stateDirectory.path)
        } catch {
            throw EngineError.launchFailed(String(localized: "无法创建 BT 状态目录，请检查访问权限", bundle: .module))
        }
        let rpc = TorrentdClient(transport: transport, requestTimeout: requestTimeout)
        do {
            try await rpc.start()
            try await rpc.waitUntilReady(timeout: readyTimeout)
            try await sendConfiguration(options: options, settings: settings, using: rpc)
            guard await rpc.isRunning() else { throw EngineError.notRunning }
        } catch {
            await rpc.finish(grace: .zero)
            throw error
        }
        let id = UUID()
        self.options = options
        client = rpc
        sessionID = id
        monitor = Task { [weak self] in
            for await _ in rpc.events { }
            await self?.didExit(id, client: rpc)
        }
    }

    private func shutdown() async {
        monitor?.cancel()
        monitor = nil
        sessionID = nil
        trackerDeliveries.removeAll()
        guard let rpc = client else { return }
        client = nil
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var saved = false
        if await rpc.isRunning() {
            do {
                let reply: [String: Bool] = try await rpc.call("shutdown", TorrentdEmpty())
                saved = reply["saved"] == true
            } catch {
                Self.logger.warning("BT 引擎未确认退出请求，将关闭输入管道并等待退出")
            }
        }
        // Only the new post-flush acknowledgement permits a short network grace.
        // Older helpers and save failures retain the full persistence deadline.
        if saved {
            await rpc.finish(grace: .milliseconds(1200), terminationGrace: .zero)
        } else {
            await rpc.finish(grace: max(.zero, ContinuousClock.now.duration(to: deadline)))
        }
    }

    private func didExit(_ id: UUID, client exited: TorrentdClient) {
        guard sessionID == id else { return }
        sessionID = nil
        trackerDeliveries.removeAll()
        client = nil
        monitor = nil
        // 退出先对 App 可见；只对同一运行周期的首次意外退出自动重启。
        guard shouldRun, !restartUsed, let options else {
            restarting = Task { await exited.finish(grace: .zero) }
            return
        }
        restartUsed = true
        restarting = Task { [weak self, restartBackoff] in
            await exited.finish(grace: .zero)
            do { try await Task.sleep(for: restartBackoff) } catch { return }
            guard let self else { return }
            await self.restart(options: options)
        }
    }

    private func restart(options: EngineOptions) async {
        guard shouldRun, stopping == nil else { return }
        let task = Task { try await launch(options: options) }
        starting = task
        defer { starting = nil }
        do { try await task.value } catch {
            Self.logger.error("BT 引擎自动重启失败")
        }
        restarting = nil
    }
}
