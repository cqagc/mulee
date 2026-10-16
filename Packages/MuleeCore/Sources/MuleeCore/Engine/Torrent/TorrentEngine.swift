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

    public func add(link: ParsedLink, directory: URL?, filePriorities: [Int]?, paused: Bool = false) async throws -> String {
        let client = try await runningClient()
        var params = TorrentdAddParameters(savePath: directory?.path, paused: paused, source: link.original)
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
        return result.id
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
            uploadLimit: task.uploadLimit, hasMetadata: task.hasMetadata
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

    public func sessionStatus() async throws -> TorrentSessionStatus {
        let client = try await runningClient()
        return try await client.call("session_status", TorrentdEmpty())
    }

    public func snapshots() async throws -> [EngineTaskSnapshot] {
        let client = try await runningClient()
        let result: TorrentdListResult = try await client.call("list", TorrentdEmpty())
        for torrent in result.torrents {
            let action = SeedingPolicy.action(
                ratio: torrent.ratio, isPrivate: torrent.isPrivate,
                paused: torrent.paused, uploadLimit: torrent.uploadLimit, settings: settings
            )
            switch action {
            case .none: break
            case .pause:
                let _: TorrentdEmpty = try await client.call("pause", TorrentdIDParameters(id: torrent.id))
            case .setUploadLimit(let limit):
                let _: TorrentdEmpty = try await client.call(
                    "set_upload_limit", TorrentdUploadLimitParameters(id: torrent.id, limit: limit)
                )
            }
        }
        return result.torrents.map(TorrentStatusMapper.snapshot)
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
        guard let rpc = client else { return }
        client = nil
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        if await rpc.isRunning() {
            do {
                let _: TorrentdEmpty = try await rpc.call("shutdown", TorrentdEmpty())
            } catch {
                Self.logger.warning("BT 引擎未确认退出请求，将关闭输入管道并等待退出")
            }
        }
        await rpc.finish(grace: max(.zero, ContinuousClock.now.duration(to: deadline)))
    }

    private func didExit(_ id: UUID, client exited: TorrentdClient) {
        guard sessionID == id else { return }
        sessionID = nil
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
