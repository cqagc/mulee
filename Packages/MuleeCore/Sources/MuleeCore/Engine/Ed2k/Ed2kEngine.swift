import Darwin
import Foundation

/// 以本机 EC 控制随 App 打包的 amuled；不提供资源搜索。
public actor Ed2kEngine: DownloadEngine {
    public nonisolated let kind: TaskKind = .ed2k

    /// 会话变化时，首次快照只用于同步，不应作为新的操作音效事件。
    public var snapshotSessionID: UUID? {
        get async { await client?.generation }
    }

    private let stateDirectory: URL
    private let binaryURL: URL?
    private var settings: Ed2kEngineSettings
    private var configuration: Ed2kConfiguration?
    private var process: Ed2kProcess?
    private var client: ECClient?
    private var stateLock: Ed2kStateLock?
    private var history: Ed2kHistory?
    private var monitor: Task<Void, Never>?
    private var busy = false
    private var categories: [String: UInt64] = [:]
    private var peers: [UInt64: [UInt16: ECTag]] = [:]
    private var peerGeneration: UUID?
    private var lastNetworkAttempt: Date?

    /// stateDirectory 由 App 传 Application Support/Mulee/amule。
    /// binaryURL 优先于 App 的 Contents/Helpers/amuled 和 MULEE_AMULED。
    public init(
        stateDirectory: URL,
        binaryURL: URL? = nil,
        settings: Ed2kEngineSettings = Ed2kEngineSettings()
    ) {
        self.stateDirectory = stateDirectory
        self.binaryURL = binaryURL
        self.settings = settings
    }

    deinit {
        monitor?.cancel()
        stateLock?.unlock()
        if let identity = process?.identity,
           identity.matches(binary: URL(fileURLWithPath: identity.executable)) {
            kill(identity.pid, SIGTERM)
        }
    }

    public func start(options: EngineOptions) async throws {
        try await lock()
        defer { busy = false }
        if process?.isRunning == true { return }
        if process != nil { await shutdown() }
        var updated = settings
        if updated.uploadLimit == 0 { updated.uploadLimit = options.uploadLimit }
        try await launch(options: options, settings: updated)
    }

    public func stop() async {
        // Task 不继承调用方的取消状态，确保退出清理执行到底。
        let cleanup = Task { await stopExclusively() }
        await cleanup.value
    }

    public func apply(options: EngineOptions) async throws {
        try await lock()
        defer { busy = false }
        let rpc = try runningClient()
        guard var updated = configuration else { throw EngineError.notRunning }
        let cacheChanged = Ed2kConfiguration.fileBufferUnits(updated.options) != Ed2kConfiguration.fileBufferUnits(options)
        updated.options = options
        updated.settings.uploadLimit = options.uploadLimit
        _ = try updated.managedValues()
        // FileBufferSizePref has no EC tag; graceful shutdown flushes part files before relaunch.
        if cacheChanged {
            await shutdown()
            try await launch(options: options, settings: updated.settings)
            return
        }
        try await sendPreferences(updated, using: rpc)
        try updated.write()
        configuration = updated
        settings = updated.settings
    }

    /// 更改端口会保存队列并重启 amuled，使监听端口立即生效。
    public func configure(_ settings: Ed2kEngineSettings, preserveBandwidth: Bool = false) async throws {
        try await lock()
        defer { busy = false }
        let rpc = try runningClient()
        guard var updated = configuration else { throw EngineError.notRunning }
        var settings = settings
        if preserveBandwidth { settings.uploadLimit = updated.options.uploadLimit }
        updated.settings = settings
        updated.options.uploadLimit = settings.uploadLimit
        _ = try updated.managedValues()
        if settings.tcpPort != self.settings.tcpPort || settings.udpPort != self.settings.udpPort
            || settings.enableKad != self.settings.enableKad || settings.connectToServers != self.settings.connectToServers
            || settings.shareCompletedFiles != self.settings.shareCompletedFiles || settings.obfuscation != self.settings.obfuscation {
            // UDP socket、共享过滤和混淆偏好需要重新读取配置；队列保存在同一状态目录。
            await shutdown()
            try await launch(options: updated.options, settings: settings)
        } else {
            try await sendPreferences(updated, using: rpc)
            try updated.write()
            configuration = updated
            self.settings = settings
            try await maintainNetworks(using: rpc, force: true)
        }
    }

    public func add(link: ParsedLink, directory: URL?) async throws -> String {
        try await lock()
        defer { busy = false }
        let rpc = try runningClient()
        guard case .ed2k(let name, let size, let hash, let original) = link,
              case .ed2k(let wireName, let wireSize, let wireHash, _) = Ed2kLinkParser.parse(ThunderLinkDecoder.decode(original) ?? original),
              hash.uppercased() == wireHash, name == wireName, size == wireSize, size > 0, let configuration else { throw EngineError.unsupportedLink }
        _ = try ECTag.hash(ECCode.Tag.partFile, hash)
        let destination = (directory ?? configuration.options.downloadDirectory).standardizedFileURL
        guard destination.isFileURL, Ed2kStatusMapper.safePath(name: name, directory: destination) != nil,
              !destination.path.contains(where: { $0.isNewline || $0 == "\0" }) else {
            throw ECError.rejected(String(localized: "文件名或保存目录无效", bundle: .module))
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let category = destination.path == configuration.options.downloadDirectory.standardizedFileURL.path
            ? 0 : try await categoryID(for: destination, using: rpc)
        let tag = ECTag.string(ECCode.Tag.string, ThunderLinkDecoder.decode(original) ?? original, children: [.number(ECCode.Tag.category, category)])
        _ = try await rpc.request(ECPacket(opcode: ECCode.Op.addLink, tags: [tag])).checked()
        let id = hash.uppercased()
        if history?.records[id] == nil {
            history?.store(Ed2kTaskRecord(hash: id, name: name, size: size, directory: destination,
                                         source: original, waitingSince: Date()))
        }
        try history?.flush(force: true)
        return id
    }

    public func pause(_ engineTaskID: String) async throws {
        try await lock()
        defer { busy = false }
        try await partCommand(ECCode.Op.pause, hash: engineTaskID)
    }

    public func resume(_ engineTaskID: String) async throws {
        try await lock()
        defer { busy = false }
        try await partCommand(ECCode.Op.resume, hash: engineTaskID)
    }

    public func remove(_ engineTaskID: String, deleteFiles: Bool) async throws {
        try await lock()
        defer { busy = false }
        let rpc = try runningClient()
        let id = engineTaskID.uppercased()
        // 刷新一次，以覆盖下载完成与用户点击删除之间的竞争。
        _ = try await collect(using: rpc)
        if let record = history?.records[id], record.completedAt != nil {
            if deleteFiles, let file = record.completedPath,
               Aria2FileSafety.isInside(file, directory: record.directory),
               FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.trashItem(at: file, resultingItemURL: nil)
            }
        } else {
            // aMule 固有语义：删除未完成任务总会删除 .part，即使 deleteFiles 为 false。
            try await partCommand(ECCode.Op.delete, hash: id)
        }
        history?.remove(id)
        try history?.flush(force: true)
    }

    public func snapshots() async throws -> [EngineTaskSnapshot] {
        try await lock()
        defer { busy = false }
        return try await collect(using: runningClient())
    }

    public func networkStatus() async throws -> Ed2kNetworkStatus {
        try await lock()
        defer { busy = false }
        let tag = try await connectionTag(using: runningClient())
        return try Ed2kNetworkStatus(tag: tag)
    }

    /// 从运行中的 EC 偏好读取；amuled 3.1.0 的服务器 UDP 使用 TCP + 3。
    public func listeningPorts() async throws -> ExtraPortMappings {
        try await lock()
        defer { busy = false }
        let response = try await runningClient().request(ECPacket(opcode: ECCode.Op.getPreferences, tags: [
            .number(ECCode.Tag.selectPreferences, 4), .number(ECCode.Tag.detail, 2)
        ])).checked(ECCode.Op.setPreferences)
        guard let preferences = response.tag(ECCode.Tag.connectionPreferences) else {
            throw ECError.malformed(String(localized: "暂时无法确认电驴实际监听端口", bundle: .module))
        }
        return try Self.portMappings(from: preferences)
    }

    static func portMappings(from preferences: ECTag) throws -> ExtraPortMappings {
        guard let tcp = preferences.tag(ECCode.Tag.tcpPort)?.number, tcp > 0, tcp <= 65532,
              let udp = preferences.tag(ECCode.Tag.udpPort)?.number, udp > 0, udp <= 65535 else {
            throw ECError.malformed(String(localized: "暂时无法确认电驴实际监听端口", bundle: .module))
        }
        let udpEnabled = preferences.tag(ECCode.Tag.udpDisabled) == nil
        return ExtraPortMappings(tcp: [Int(tcp)], udp: udpEnabled ? [Int(tcp) + 3, Int(udp)] : [Int(tcp) + 3])
    }

    /// 映射首次就绪后重新获取服务器和 Kad 的连入判断。
    public func recheckConnectivity() async throws {
        try await lock()
        defer { busy = false }
        let rpc = try runningClient()
        let status = try Ed2kNetworkStatus(tag: await connectionTag(using: rpc))
        if settings.connectToServers, status.ed2kID != .high {
            _ = try await rpc.request(ECPacket(opcode: ECCode.Op.serverDisconnect)).checked()
        }
        if settings.enableKad, status.kad != .open {
            _ = try await rpc.request(ECPacket(opcode: ECCode.Op.kadStop)).checked()
        }
        try await maintainNetworks(using: rpc, force: true)
    }

    private func lock() async throws {
        while busy { try await Task.sleep(for: .milliseconds(10)) }
        try Task.checkCancellation()
        busy = true
    }

    private func runningClient() throws -> ECClient {
        guard process?.isRunning == true, let client else { throw EngineError.notRunning }
        return client
    }

    private func partCommand(_ opcode: UInt8, hash: String) async throws {
        let rpc = try runningClient()
        _ = try await rpc.request(ECPacket(opcode: opcode, tags: [try .hash(ECCode.Tag.partFile, hash)])).checked()
    }

    private func launch(options: EngineOptions, settings: Ed2kEngineSettings) async throws {
        let binary = try Ed2kBinaryLocator.locate(explicitURL: binaryURL)
        let configuration = Ed2kConfiguration(
            stateDirectory: stateDirectory, port: try ECLoopback.availablePort(), password: UUID().uuidString + UUID().uuidString,
            options: options, settings: settings
        )
        _ = try configuration.managedValues()
        stateLock = try Ed2kStateLock(directory: stateDirectory)
        do {
            try await Ed2kProcess.recover(stateDirectory: stateDirectory, binary: binary)
            history = try Ed2kHistory(directory: stateDirectory)
            try configuration.write()
            let child = try Ed2kProcess(binary: binary, stateDirectory: stateDirectory)
            process = child
            try Ed2kConfiguration.writePrivate(JSONEncoder().encode(child.identity), to: processRecordURL)
            let rpc = ECClient(port: configuration.port, password: configuration.password)
            client = rpc
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            var ready = false
            while child.isRunning && ContinuousClock.now < deadline {
                do {
                    try await rpc.connect(deadline: min(deadline, ContinuousClock.now.advanced(by: .seconds(1))))
                    ready = true
                    break
                } catch is CancellationError {
                    throw CancellationError()
                } catch ECError.authentication {
                    throw ECError.authentication
                } catch {
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            guard child.isRunning else {
                throw EngineError.launchFailed(String(localized: "电驴引擎在连接就绪前退出，电驴任务暂时无法下载。请检查保存目录权限和引擎日志后重试。", bundle: .module))
            }
            guard ready else {
                throw EngineError.launchFailed(String(localized: "电驴引擎启动超过 30 秒，电驴任务暂时无法下载。若有文件夹访问提示，请先允许访问，再重试；仍失败时请查看引擎日志。", bundle: .module))
            }
            self.configuration = configuration
            self.settings = settings
            categories.removeAll()
            peers.removeAll()
            peerGeneration = nil
            // 3.1.0 amule.cpp 的 AMULE_DAEMON 分支会按配置中的 HTTPS URL
            // 自动获取缺失的 server.met / nodes.dat，不能再发 EC 更新造成重复下载。
            try await maintainNetworks(using: rpc, force: true)
            monitor = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    await self?.tick()
                }
            }
        } catch {
            await shutdown()
            throw error
        }
    }

    private var processRecordURL: URL { stateDirectory.appendingPathComponent("mulee-process.json") }

    private func stopExclusively() async {
        do { try await lock() } catch { return }
        defer { busy = false }
        await shutdown()
    }

    private func shutdown() async {
        monitor?.cancel()
        monitor = nil
        let rpc = client
        client = nil
        let ownedProcess = process
        if let ownedProcess {
            if let rpc {
                // 正常退出先通知 EC；macOS 事件循环未退出时再用等价的保存信号兜底。
                _ = try? await Task { try await rpc.request(ECPacket(opcode: ECCode.Op.shutdown)) }.value
            }
            await ownedProcess.finish(waitForExit: .milliseconds(250))
        }
        process = nil
        await rpc?.disconnect()
        do {
            try history?.flush(force: true)
            if let ownedProcess, FileManager.default.fileExists(atPath: processRecordURL.path),
               let saved = try? JSONDecoder().decode(Ed2kProcessIdentity.self, from: Data(contentsOf: processRecordURL)),
               saved == ownedProcess.identity {
                try FileManager.default.removeItem(at: processRecordURL)
            }
            if let configuration {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configuration.url.path)
            }
        } catch {
            Ed2kProcess.logger.error("保存电驴状态失败：\(error.localizedDescription, privacy: .public)")
        }
        history?.resetObservations()
        stateLock?.unlock()
        stateLock = nil
        configuration = nil
        lastNetworkAttempt = nil
    }

    private func tick() async {
        do {
            try await lock()
            defer { busy = false }
            let rpc = try runningClient()
            _ = try await collect(using: rpc)
            try await maintainNetworks(using: rpc)
        } catch is CancellationError {
            return
        } catch {
            Ed2kProcess.logger.warning("读取电驴状态失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    private func sendPreferences(_ configuration: Ed2kConfiguration, using rpc: ECClient) async throws {
        let settings = configuration.settings
        let connection = ECTag.empty(ECCode.Tag.connectionPreferences, children: [
            .number(ECCode.Tag.tcpPort, UInt64(settings.tcpPort)),
            .number(ECCode.Tag.udpPort, UInt64(settings.udpPort)),
            .number(ECCode.Tag.udpDisabled, settings.connectToServers || settings.enableKad ? 0 : 1),
            .number(ECCode.Tag.ed2kEnabled, settings.connectToServers ? 1 : 0),
            .number(ECCode.Tag.kadEnabled, settings.enableKad ? 1 : 0),
            .number(ECCode.Tag.autoconnect, settings.connectToServers || settings.enableKad ? 1 : 0),
            .number(ECCode.Tag.reconnect, settings.connectToServers || settings.enableKad ? 1 : 0),
            .number(ECCode.Tag.downloadLimit, try Ed2kConfiguration.limitInKiB(configuration.options.downloadLimit), width: 4),
            .number(ECCode.Tag.uploadLimit, try Ed2kConfiguration.limitInKiB(settings.uploadLimit), width: 4)
        ])
        _ = try await rpc.request(ECPacket(opcode: ECCode.Op.setPreferences, tags: [
            .number(ECCode.Tag.detail, 2), connection,
            .empty(ECCode.Tag.directoryPreferences, children: [
                .string(ECCode.Tag.incomingDirectory, configuration.options.downloadDirectory.path)
            ])
        ])).checked()
    }

    private func categoryID(for directory: URL, using rpc: ECClient) async throws -> UInt64 {
        if let id = categories[directory.path] { return id }
        let existing = try await readCategories(using: rpc)
        if let id = existing[directory.path] { return id }
        _ = try await rpc.request(ECPacket(opcode: ECCode.Op.createCategory, tags: [
            .number(ECCode.Tag.categoryEntry, 0, children: [
                .string(ECCode.Tag.categoryTitle, "Mulee · " + directory.lastPathComponent),
                .string(ECCode.Tag.categoryPath, directory.path),
                .string(ECCode.Tag.categoryComment, ""),
                .number(ECCode.Tag.categoryColor, 0), .number(ECCode.Tag.categoryPriority, 1)
            ])
        ])).checked()
        let updated = try await readCategories(using: rpc)
        guard let id = updated[directory.path] else { throw ECError.rejected(String(localized: "分类创建后无法确认保存目录", bundle: .module)) }
        return id
    }

    @discardableResult
    private func readCategories(using rpc: ECClient) async throws -> [String: UInt64] {
        let response = try await rpc.request(ECPacket(opcode: ECCode.Op.getPreferences, tags: [
            .number(ECCode.Tag.selectPreferences, 1), .number(ECCode.Tag.detail, 2)
        ])).checked(ECCode.Op.setPreferences)
        var updated: [String: UInt64] = [:]
        for tag in response.tag(ECCode.Tag.categories)?.children ?? [] {
            if let path = tag.tag(ECCode.Tag.categoryPath)?.string, let id = tag.number {
                updated[URL(fileURLWithPath: path).standardizedFileURL.path] = id
            }
        }
        categories = updated
        return updated
    }

    private func connectionTag(using rpc: ECClient) async throws -> ECTag {
        let packet = try await rpc.request(ECPacket(opcode: ECCode.Op.getConnectionState, tags: [.number(ECCode.Tag.detail, 2)]))
            .checked(ECCode.Op.miscData)
        guard let tag = packet.tag(ECCode.Tag.connectionState) else { throw ECError.malformed(String(localized: "缺少网络状态", bundle: .module)) }
        return tag
    }

    private func maintainNetworks(using rpc: ECClient, force: Bool = false) async throws {
        guard settings.connectToServers || settings.enableKad else { return }
        let now = Date()
        guard force || lastNetworkAttempt.map({ now.timeIntervalSince($0) >= 30 }) ?? true else { return }
        lastNetworkAttempt = now
        let tag = try await connectionTag(using: rpc)
        let flags = tag.number ?? 0
        if settings.connectToServers, flags & 3 == 0 {
            _ = try await rpc.request(ECPacket(opcode: ECCode.Op.serverConnect)).checked()
        }
        if settings.enableKad, flags & 0x10 == 0 {
            _ = try await rpc.request(ECPacket(opcode: ECCode.Op.kadStart)).checked()
        }
    }

    private func collect(using rpc: ECClient) async throws -> [EngineTaskSnapshot] {
        let downloads = try await rpc.request(ECPacket(opcode: ECCode.Op.getDownloads, tags: [.number(ECCode.Tag.detail, 2)]))
            .checked(ECCode.Op.downloads)
        let shared = try await rpc.request(ECPacket(opcode: ECCode.Op.getShared, tags: [.number(ECCode.Tag.detail, 2)]))
            .checked(ECCode.Op.shared)
        let update = try await rpc.request(ECPacket(opcode: ECCode.Op.getUpdate, tags: [.number(ECCode.Tag.detail, 4)]))
            .checked(ECCode.Op.shared)
        let generation = await rpc.generation
        if generation != peerGeneration {
            peers.removeAll()
            history?.resetObservations()
            peerGeneration = generation
        }
        let clientTags = update.tag(ECCode.Tag.client)?.children ?? []
        let alive = Set(clientTags.compactMap(\.number))
        peers = peers.filter { alive.contains($0.key) }
        for tag in clientTags {
            guard let id = tag.number else { continue }
            for child in tag.children { peers[id, default: [:]][child.name] = child }
        }
        let categoryPaths = try await readCategories(using: rpc)
        let now = Date()
        var result: [EngineTaskSnapshot] = []
        var active: Set<String> = []
        var completedChanged = false
        for tag in downloads.tags where tag.name == ECCode.Tag.partFile {
            guard let hash = tag.tag(ECCode.Tag.fileHash)?.hash,
                  let name = tag.tag(ECCode.Tag.name)?.string,
                  let size = tag.tag(ECCode.Tag.size)?.number else { throw ECError.malformed(String(localized: "下载队列缺少文件信息", bundle: .module)) }
            active.insert(hash)
            let category = tag.tag(ECCode.Tag.category)?.number ?? 0
            let directory = categoryPaths.first { $0.value == category }.map { URL(fileURLWithPath: $0.key) }
                ?? configuration?.options.downloadDirectory ?? stateDirectory
            var record = history?.records[hash] ?? Ed2kTaskRecord(
                hash: hash, name: name, size: Int64(clamping: size), directory: directory, waitingSince: now
            )
            record.name = name
            record.directory = directory
            record.size = Int64(clamping: size)
            // 恢复的同 hash 未完成任务不能继承旧的 completed 标志。
            if tag.tag(ECCode.Tag.status)?.number != 9 {
                record.completedAt = nil
                record.completedPath = nil
            } else if record.completedAt == nil {
                record.completedAt = now
                record.completedPath = Ed2kStatusMapper.safePath(name: name, directory: directory)
                completedChanged = true
            }
            history?.store(record)
            let timestamp = tag.tag(ECCode.Tag.lastComplete)?.number ?? 0
            history?.observe(hash, received: Int64(clamping: tag.tag(ECCode.Tag.received)?.number ?? 0),
                             rate: Int64(clamping: tag.tag(ECCode.Tag.speed)?.number ?? 0),
                             sources: Int(clamping: tag.tag(ECCode.Tag.sources)?.number ?? 0),
                             lastComplete: timestamp > 0 ? Date(timeIntervalSince1970: Double(timestamp)) : nil, now: now)
            let ecid = tag.number
            let rank = peers.values.compactMap { peer -> Int? in
                guard let ecid, peer[ECCode.Tag.requestFile]?.number == ecid,
                      let value = peer[ECCode.Tag.queueRank]?.number, value > 0, value < 0xffff else { return nil }
                return Int(value)
            }.min()
            if let current = history?.records[hash] {
                var snapshot = try Ed2kStatusMapper.snapshot(tag: tag, record: current, rank: rank, now: now)
                snapshot.writeDirectories = [current.directory]
                if snapshot.status != .completed, let temporary = configuration?.temporaryDirectory {
                    snapshot.writeDirectories?.append(temporary)
                }
                result.append(snapshot)
            }
        }
        for tag in shared.tags where tag.name == ECCode.Tag.knownFile {
            guard let hash = tag.tag(ECCode.Tag.fileHash)?.hash, !active.contains(hash),
                  var record = history?.records[hash] else { continue }
            guard let path = tag.tag(ECCode.Tag.filePath)?.string,
                  let name = tag.tag(ECCode.Tag.name)?.string,
                  let completed = Ed2kStatusMapper.safePath(name: name, directory: URL(fileURLWithPath: path)),
                  Aria2FileSafety.isInside(completed, directory: record.directory) else { continue }
            if record.completedAt == nil || record.completedPath != completed { completedChanged = true }
            record.completedAt = record.completedAt ?? now
            record.completedPath = completed
            record.name = name
            record.received = record.size
            history?.store(record)
        }
        for record in history?.records.values ?? Dictionary<String, Ed2kTaskRecord>().values where !active.contains(record.hash) && record.completedAt != nil {
            result.append(Ed2kStatusMapper.completed(record, now: now))
        }
        if completedChanged, !settings.shareCompletedFiles {
            // aMule 完成文件时会直接加入共享，重新扫描后按 ExcludeSharePatterns 排除。
            _ = try await rpc.request(ECPacket(opcode: ECCode.Op.reloadShared)).checked()
        }
        try history?.flush(force: completedChanged)
        return result.sorted { $0.engineTaskID < $1.engineTaskID }
    }
}
