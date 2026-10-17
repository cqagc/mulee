import Foundation

/// HTTP / HTTPS / FTP 下载引擎：以子进程运行 aria2c，通过本机 JSON-RPC 控制。
public actor Aria2Engine: DownloadEngine {
    public nonisolated let kind: TaskKind = .http

    private let stateDirectory: URL
    private let binaryURL: URL?
    private var process: Aria2Process?
    private var client: Aria2RPCClient?
    private var configuration: Aria2Configuration?
    private var starting: Task<Void, any Error>?
    private var stopping: Task<Void, Never>?
    private let proxyProvider: @Sendable () -> HTTPProxyConfiguration
    private var proxyMonitor: Task<Void, Never>?
    private var proxyRestoredTaskIDs: Set<String> = []
    private var streamSelectors: [String: String] = [:]
    private var permissionMonitor: Task<Void, Never>?
    private var incompleteTransfers: [String: IncompleteHTTPTransfer] = [:]
    private var finalizedFiles: [String: URL] = [:]
    private var resumeAttempts: [String: UUID] = [:]

    /// - Parameters:
    ///   - stateDirectory: 存放 aria2 配置、会话、日志的目录（App 传 Application Support/Mulee/aria2）。
    ///   - binaryURL: 指定 aria2c 路径；nil 时按 App 包内 Helpers、环境变量 MULEE_ARIA2C 依次查找。
    public init(
        stateDirectory: URL, binaryURL: URL? = nil,
        proxyProvider: @escaping @Sendable () -> HTTPProxyConfiguration = { .current() }
    ) {
        self.stateDirectory = stateDirectory
        self.binaryURL = binaryURL
        self.proxyProvider = proxyProvider
    }

    public func start(options: EngineOptions) async throws {
        if let stopping { await stopping.value }
        if let starting { return try await starting.value }
        if process?.isRunning == true, client != nil { return }
        let task = Task { try await launch(options: options) }
        starting = task
        defer { starting = nil }
        try await task.value
    }

    public func stop() async {
        if let stopping { return await stopping.value }
        let task = Task {
            if let starting {
                do { try await starting.value } catch {
                    Aria2Process.logger.warning("停止前启动失败：\(error.localizedDescription, privacy: .public)")
                }
            }
            await shutdown()
        }
        stopping = task
        await task.value
        stopping = nil
    }

    public func apply(options: EngineOptions) async throws {
        let client = try runningClient()
        guard var updated = configuration else { throw EngineError.notRunning }
        let cacheChanged = max(0, updated.options.diskCacheMegabytes) != max(0, options.diskCacheMegabytes)
        updated.options = options
        updated.proxy = proxyProvider()
        // Validate before changing the running process; disk-cache is startup-only.
        _ = try updated.contents()
        if cacheChanged {
            // SIGINT flushes the cache and session; launch restores active and paused tasks.
            await stop()
            try await start(options: options)
            return
        }
        let values = updated.runtimeOptions.mapValues { Aria2RPCValue.string($0) }
        let _: String = try await client.call("aria2.changeGlobalOption", [.object(values)])
        try updated.write()
        configuration = updated
    }

    public func add(link: ParsedLink, directory: URL?) async throws -> String {
        try await add(link: link, directory: directory, context: .init(), paused: false)
    }

    public func addQueued(link: ParsedLink, directory: URL?) async throws -> String {
        try await add(link: link, directory: directory, context: .init(), paused: true)
    }

    public func add(
        link: ParsedLink, directory: URL?, context: DownloadRequestContext,
        checksum: DownloadChecksum? = nil, paused: Bool = false,
        httpThreads: Int? = nil, speedLimitBytes: Int64? = nil,
        incompleteTaskID: UUID? = nil
    ) async throws -> String {
        let client = try runningClient()
        if case .http(let url, _, _) = link, HTTPMetalink.recognizes(url) {
            return try await addMetalink(url, directory: directory, paused: paused)
        }
        guard case .http(let url, _, _) = link,
              let scheme = url.scheme?.lowercased(), ["http", "https", "ftp"].contains(scheme) else {
            throw EngineError.unsupportedLink
        }
        let prepared = try await HTTPResourceProbe.prepareDownload(url, context: context)
        let context = prepared.context
        var params: [Aria2RPCValue] = [.array([.string(prepared.url.absoluteString)])]
        var values = try Aria2RequestOptions.values(context: context, checksum: checksum)
        if let httpThreads {
            let threads = String(min(16, max(1, httpThreads)))
            values["split"] = .string(threads)
            values["max-connection-per-server"] = .string(threads)
        }
        if let speedLimitBytes { values["max-download-limit"] = .string(String(max(0, speedLimitBytes))) }
        var transfer: IncompleteHTTPTransfer?
        if let incompleteTaskID, let destination = directory ?? configuration?.options.downloadDirectory {
            let pending = IncompleteHTTPTransfer(
                taskID: incompleteTaskID, destination: destination, duplicateAction: context.duplicateAction ?? .rename
            )
            try pending.prepare()
            values["dir"] = .string(pending.directory.path)
            transfer = pending
        } else if let directory { values["dir"] = .string(directory.path) }
        values["pause"] = .string(paused ? "true" : "false")
        if !values.isEmpty { params.append(.object(values)) }
        let id: String = try await client.call("aria2.addUri", params)
        if let transfer {
            incompleteTransfers[id] = transfer
            try saveIncompleteTransfers()
        }
        return id
    }

    /// 保留任务路径与控制文件，停态 GID 先重建为暂停任务，再用 changeUri 换链。
    public func replaceURI(
        _ engineTaskID: String, with url: URL, context: DownloadRequestContext,
        checksum: DownloadChecksum?, restartFromScratch: Bool = false
    ) async throws -> String {
        resumeAttempts[engineTaskID] = nil
        let client = try runningClient()
        var status = try await taskStatus(engineTaskID, using: client)
        let transfer = incompleteTransfers[engineTaskID]
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else { throw EngineError.unsupportedLink }
        if ["active", "waiting"].contains(status.status) {
            try await pause(engineTaskID)
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            repeat {
                status = try await taskStatus(engineTaskID, using: client)
                if ["paused", "error", "complete", "removed"].contains(status.status) { break }
                guard ContinuousClock.now < deadline else { throw EngineError.invalidResponse("等待暂停下载超时") }
                try await Task.sleep(for: .milliseconds(25))
            } while true
        }
        let prepared = try await HTTPResourceProbe.prepareDownload(url, context: context)
        let url = prepared.url
        var context = prepared.context
        if let path = status.files?.first?.path, !path.isEmpty {
            context.suggestedFilename = URL(fileURLWithPath: path).lastPathComponent
        } else if let file = transfer?.workingFile {
            context.suggestedFilename = file.lastPathComponent
        }
        var values = try Aria2RequestOptions.values(context: context, checksum: checksum)
        if let directory = status.dir { values["dir"] = .string(directory) }
        values["pause"] = .string("true")
        values["auto-file-renaming"] = .string("false")
        values["continue"] = .string(restartFromScratch ? "false" : "true")
        let previousURIs = status.files?.first?.uris?.map(\.uri) ?? []
        var id = engineTaskID
        if restartFromScratch {
            try await remove(engineTaskID, deleteFiles: true, preservingIncomplete: true)
            let replacement: String = try await client.call("aria2.addUri", [.array([.string(url.absoluteString)]), .object(values)])
            try rekeyIncomplete(engineTaskID, to: replacement, transfer: transfer, restarting: true)
            return replacement
        }
        if ["error", "complete", "removed"].contains(status.status) {
            // aria2 的 changeUri 不接受 stopped 结果；同路径加载 .aria2 分块进度。
            id = try await client.call("aria2.addUri", [.array([.string(url.absoluteString)]), .object(values)])
            do {
                let _: String = try await client.call("aria2.removeDownloadResult", [.string(engineTaskID)])
            } catch {
                try? await remove(id, deleteFiles: false)
                throw error
            }
            try rekeyIncomplete(engineTaskID, to: id, transfer: transfer)
            return id
        } else {
            try await pause(id)
            var updated = try Aria2RequestOptions.values(context: context, checksum: checksum)
            if transfer == nil { updated.removeValue(forKey: "out") }
            updated["header"] = updated["header"] ?? .string("")
            updated["referer"] = updated["referer"] ?? .string("")
            let _: String = try await client.call("aria2.changeOption", [.string(id), .object(updated)])
        }
        let changed: [Int] = try await client.call("aria2.changeUri", [
            .string(id), .integer(1), .array(previousURIs.map(Aria2RPCValue.string)),
            .array([.string(url.absoluteString)]), .integer(0)
        ])
        guard changed.count == 2, changed[1] == 1 else {
            throw EngineError.invalidResponse("无法替换下载链接")
        }
        try rekeyIncomplete(engineTaskID, to: id, transfer: transfer)
        return id
    }

    /// 仅标记已补齐代理选项的恢复任务；是否继续由 App 的暂停原因和并发队列决定。
    public func takeProxyRestoredTaskIDs() -> Set<String> {
        defer { proxyRestoredTaskIDs.removeAll() }
        return proxyRestoredTaskIDs
    }

    public func refreshProxy() async throws {
        let client = try runningClient()
        guard var updated = configuration else { throw EngineError.notRunning }
        let proxy = proxyProvider()
        guard proxy != updated.proxy else { return }
        let _: String = try await client.call("aria2.changeGlobalOption", [.object(proxy.aria2Options.mapValues(Aria2RPCValue.string))])
        updated.proxy = proxy
        try updated.write()
        configuration = updated
    }

    private func addMetalink(_ url: URL, directory: URL?, paused: Bool) async throws -> String {
        let client = try runningClient()
        let data = try await HTTPMetalink.load(url, proxy: proxyProvider())
        var values: [String: Aria2RPCValue] = ["pause": .string(paused ? "true" : "false")]
        if let directory { values["dir"] = .string(directory.path) }
        let ids: [String] = try await client.call("aria2.addMetalink", [.string(data.base64EncodedString()), .object(values)])
        guard let id = ids.first else { throw EngineError.invalidResponse(String(localized: "Metalink 中没有可下载的文件", bundle: .module)) }
        return id
    }

    public func addMirror(_ id: String, url: URL, original: HTTPResourceIdentity, context: DownloadRequestContext = .init()) async throws {
        let client = try runningClient()
        let status = try await taskStatus(id, using: client)
        guard status.status == "active" else { throw EngineError.invalidResponse(String(localized: "仅正在下载的任务可以添加镜像地址", bundle: .module)) }
        guard url.user == nil, url.password == nil else { throw EngineError.unsupportedLink }
        // 镜像不继承原服务器的 Cookie 和认证头。
        var safeContext = context.withoutCookie
        safeContext.headers = safeContext.headers.filter { !["authorization", "proxy-authorization"].contains($0.key.lowercased()) }
        safeContext.usesStoredHTTPCredentials = false
        let options: [String: String] = try await client.call("aria2.getOption", [.string(id)])
        let hasCredentials = (options["header"] ?? "").lowercased().components(separatedBy: "\n").contains {
            $0.hasPrefix("authorization:") || $0.hasPrefix("cookie:") || $0.hasPrefix("proxy-authorization:")
        }
        var mirrorURL = url
        if hasCredentials {
            // aria2 的自定义头作用于整项任务；凭据任务只接受同源镜像。
            guard let source = (status.files?.first?.uris?.first?.uri).flatMap({ URL(string: $0) }),
                  HTTPResourceProbe.sameHost(source, url), source.scheme?.lowercased() == url.scheme?.lowercased() else {
                throw EngineError.invalidResponse(String(localized: "此任务使用登录信息，只能添加同一服务器的镜像地址。", bundle: .module))
            }
            let authenticated = Self.requestContext(headers: (options["header"] ?? "").components(separatedBy: "\n"))
            let prepared = try await HTTPResourceProbe.prepareDownload(url, context: authenticated)
            guard HTTPResourceProbe.sameHost(source, prepared.url), source.scheme?.lowercased() == prepared.url.scheme?.lowercased() else {
                throw EngineError.invalidResponse(String(localized: "镜像跳转到了其他服务器，未附加原服务器的登录信息。", bundle: .module))
            }
            mirrorURL = prepared.url
            safeContext = prepared.context
        }
        let identity = try await HTTPResourceProbe.inspect(mirrorURL, context: safeContext)
        try original.validateReplacement(identity)
        let current = try await taskStatus(id, using: client)
        guard current.status == "active" else { throw CancellationError() }
        let changed: [Int] = try await client.call("aria2.changeUri", [
            .string(id), .integer(1), .array([]), .array([.string(mirrorURL.absoluteString)])
        ])
        guard changed.count == 2, changed[1] == 1 else { throw EngineError.invalidResponse(String(localized: "未能添加镜像地址", bundle: .module)) }
    }

    public func setStreaming(_ id: String, enabled: Bool) async throws {
        let client = try runningClient()
        if enabled {
            if streamSelectors[id] == nil {
                let options: [String: String] = try await client.call("aria2.getOption", [.string(id)])
                streamSelectors[id] = options["stream-piece-selector"] ?? "default"
            }
            let _: String = try await client.call("aria2.changeOption", [.string(id), .object(["stream-piece-selector": .string("inorder")])])
        } else if let previous = streamSelectors[id] {
            do {
                let status = try await taskStatus(id, using: client)
                // 停态结果不再选择分块，也不能 changeOption；恢复时按常规选项重建。
                if ["complete", "error", "removed"].contains(status.status) {
                    streamSelectors[id] = nil
                    return
                }
                let _: String = try await client.call("aria2.changeOption", [.string(id), .object(["stream-piece-selector": .string(previous)])])
                streamSelectors[id] = nil
            } catch let error as EngineError {
                guard case .rpc(let code, _) = error, code == 1 else { throw error }
                // 删除任务可能先于播放清理；只在 GID 确实消失时忽略。
                do { _ = try await taskStatus(id, using: client) }
                catch let missing as EngineError {
                    guard case .rpc(let code, _) = missing, code == 1 else { throw missing }
                    streamSelectors[id] = nil
                    return
                }
                throw error
            }
        }
    }

    public func streamingProgress(_ id: String) async throws -> (file: URL?, size: Int64, contiguous: Int64, finished: Bool) {
        let status = try await taskStatus(id, using: runningClient())
        guard ["active", "waiting", "paused", "complete"].contains(status.status) else {
            throw EngineError.invalidResponse(String(localized: "下载已停止，无法继续缓冲", bundle: .module))
        }
        let size = Int64(status.totalLength ?? "") ?? 0
        let file = finalizedFiles[id] ?? status.files?.first.flatMap { $0.path.isEmpty ? nil : URL(filePath: $0.path) }
        return (file, size, HTTPStreamingProgress.contiguousBytes(
            bitfield: status.bitfield ?? "", numPieces: Int(status.numPieces ?? "") ?? 0,
            pieceLength: Int64(status.pieceLength ?? "") ?? 0, totalLength: size
        ), status.status == "complete")
    }

    public func setChecksum(_ engineTaskID: String, checksum: DownloadChecksum?) async throws -> String {
        let client = try runningClient()
        guard let checksum else {
            let options: [String: String] = try await client.call("aria2.getOption", [.string(engineTaskID)])
            guard let previous = options["checksum"], !previous.isEmpty else { return engineTaskID }
            let status = try await taskStatus(engineTaskID, using: client)
            guard let uri = status.files?.first?.uris?.first?.uri else { throw EngineError.unsupportedLink }
            var updated = options.mapValues(Aria2RPCValue.string)
            updated.removeValue(forKey: "checksum")
            updated.removeValue(forKey: "gid")
            updated["pause"] = .string("true")
            updated["continue"] = .string("true")
            updated["auto-file-renaming"] = .string("false")
            if let path = status.files?.first?.path, !path.isEmpty {
                updated["out"] = .string(URL(fileURLWithPath: path).lastPathComponent)
            }
            // aria2 不接受空 checksum；清除时按原路径重建暂停任务，保留分块文件。
            let transfer = incompleteTransfers[engineTaskID]
            try await remove(engineTaskID, deleteFiles: false, preservingIncomplete: true)
            let replacement: String = try await client.call("aria2.addUri", [.array([.string(uri)]), .object(updated)])
            try rekeyIncomplete(engineTaskID, to: replacement, transfer: transfer)
            return replacement
        }
        let _: String = try await client.call("aria2.changeOption", [
            .string(engineTaskID), .object(["checksum": .string(checksum.aria2Value)])
        ])
        return engineTaskID
    }

    public func setTaskLimits(id: String, download: Int64, upload: Int64) async throws {
        let client = try runningClient()
        let _: String = try await client.call("aria2.changeOption", [
            .string(id), .object(["max-download-limit": .string(String(max(0, download)))])
        ])
    }

    public func pause(_ engineTaskID: String) async throws {
        resumeAttempts[engineTaskID] = nil
        let client = try runningClient()
        do {
            let _: String = try await client.call("aria2.pause", [.string(engineTaskID)])
        } catch let error as EngineError {
            // A second pause is idempotent; unrelated RPC failures remain visible.
            guard case .rpc = error else { throw error }
            let status = try await taskStatus(engineTaskID, using: client)
            guard status.status == "paused" else { throw error }
        }
    }

    public func resume(_ engineTaskID: String) async throws {
        let client = try runningClient()
        let attempt = UUID()
        resumeAttempts[engineTaskID] = attempt
        defer {
            if resumeAttempts[engineTaskID] == attempt { resumeAttempts[engineTaskID] = nil }
        }
        let options: [String: String] = try await client.call("aria2.getOption", [.string(engineTaskID)])
        var context = Self.requestContext(headers: (options["header"] ?? "").components(separatedBy: "\n"))
        context.userAgent = options["user-agent"]
        context.referer = options["referer"].flatMap { URL(string: $0) }
        if context.requestCookie != nil || context.headers.keys.contains(where: {
            ["authorization", "proxy-authorization"].contains($0.lowercased())
        }) {
            let status = try await taskStatus(engineTaskID, using: client)
            guard let uris = status.files?.first?.uris?.map(\.uri),
                  let uri = uris.first, let url = URL(string: uri) else { throw EngineError.unsupportedLink }
            let prepared = try await HTTPResourceProbe.prepareDownload(url, context: context)
            // 用户暂停可能发生在网络预检期间，迟到的恢复不能再启动写盘。
            guard resumeAttempts[engineTaskID] == attempt else { return }
            var values = try Aria2RequestOptions.values(context: prepared.context, checksum: nil)
            values["header"] = values["header"] ?? .string("")
            let _: String = try await client.call("aria2.changeOption", [.string(engineTaskID), .object(values)])
            guard resumeAttempts[engineTaskID] == attempt else { return }
            if prepared.url != url {
                let _: [Int] = try await client.call("aria2.changeUri", [
                    .string(engineTaskID), .integer(1), .array(uris.map(Aria2RPCValue.string)),
                    .array([.string(prepared.url.absoluteString)]), .integer(0)
                ])
            }
        }
        guard resumeAttempts[engineTaskID] == attempt else { return }
        let _: String = try await client.call("aria2.unpause", [.string(engineTaskID)])
    }

    public func remove(_ engineTaskID: String, deleteFiles: Bool) async throws {
        try await remove(engineTaskID, deleteFiles: deleteFiles, preservingIncomplete: false)
    }

    private func remove(_ engineTaskID: String, deleteFiles: Bool, preservingIncomplete: Bool) async throws {
        resumeAttempts[engineTaskID] = nil
        let client = try runningClient()
        var status: Aria2RPCModels.Status
        do { status = try await taskStatus(engineTaskID, using: client) }
        catch let error as EngineError {
            if case .rpc(let code, _) = error, code == 1, (incompleteTransfers[engineTaskID] != nil || finalizedFiles[engineTaskID] != nil), !preservingIncomplete {
                if deleteFiles, let file = finalizedFiles[engineTaskID], FileManager.default.fileExists(atPath: file.path) {
                    try FileManager.default.trashItem(at: file, resultingItemURL: nil)
                }
                try discardIncomplete(engineTaskID, deleteFiles: deleteFiles)
                return
            }
            throw error
        }
        if ["active", "waiting", "paused"].contains(status.status) {
            do {
                let _: String = try await client.call("aria2.forceRemove", [.string(engineTaskID)])
            } catch let error as EngineError {
                guard case .rpc = error else { throw error }
                status = try await taskStatus(engineTaskID, using: client)
                // Completion can race the removal request.
                guard ["complete", "error", "removed"].contains(status.status) else { throw error }
            }
            // forceRemove schedules removal. Wait until it enters the stopped results.
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            repeat {
                do {
                    status = try await taskStatus(engineTaskID, using: client)
                } catch let error as EngineError {
                    // 尚未启动的暂停任务直接从 waiting 队列移除，不产生 stopped 结果。
                    // GID 在成功 forceRemove 后消失同样表示移除完成；传输错误仍向上传递。
                    guard case .rpc(let code, _) = error, code == 1 else { throw error }
                    if deleteFiles {
                        if preservingIncomplete { try Aria2FileSafety.trashFiles(for: status) }
                        else { try trashFiles(for: status) }
                    }
                    if !preservingIncomplete { try discardIncomplete(engineTaskID, deleteFiles: deleteFiles) }
                    return
                }
                if ["complete", "error", "removed"].contains(status.status) { break }
                guard ContinuousClock.now < deadline else {
                    throw EngineError.rpc(code: 1, message: String(localized: "等待 aria2 移除任务超时", bundle: .module))
                }
                try await Task.sleep(for: .milliseconds(25))
            } while true
        }
        let _: String = try await client.call("aria2.removeDownloadResult", [.string(engineTaskID)])
        if deleteFiles {
            if preservingIncomplete { try Aria2FileSafety.trashFiles(for: status) }
            else { try trashFiles(for: status) }
        }
        if !preservingIncomplete { try discardIncomplete(engineTaskID, deleteFiles: deleteFiles) }
    }

    public func snapshots() async throws -> [EngineTaskSnapshot] {
        try configuration?.protectStateFiles()
        let client = try runningClient()
        let keys = Aria2RPCValue.array(Aria2RPCModels.Status.keys.map { .string($0) })
        let active: [Aria2RPCModels.Status] = try await client.call("aria2.tellActive", [keys])
        let waiting: [Aria2RPCModels.Status] = try await client.call(
            "aria2.tellWaiting", [.integer(0), .integer(1000), keys]
        )
        let stopped: [Aria2RPCModels.Status] = try await client.call(
            "aria2.tellStopped", [.integer(0), .integer(1000), keys]
        )
        var changed = false
        var snapshots = (active + waiting + stopped).compactMap(Aria2StatusMapper.snapshot).map { snapshot in
            var snapshot = snapshot
            if var transfer = incompleteTransfers[snapshot.engineTaskID] {
                if let file = snapshot.savePath, transfer.workingFile != file, transfer.completedFile == nil {
                    transfer.recordWorkingFile(file)
                    incompleteTransfers[snapshot.engineTaskID] = transfer
                    changed = true
                }
                if snapshot.status == .completed, let file = snapshot.savePath,
                   transfer.downloadedBytes != snapshot.receivedBytes, transfer.completedFile == nil {
                    transfer.recordCompletion(file: file, bytes: snapshot.receivedBytes)
                    incompleteTransfers[snapshot.engineTaskID] = transfer
                    changed = true
                }
                if let file = transfer.completedFile {
                    snapshot.savePath = file
                    snapshot.name = file.lastPathComponent
                    snapshot.writeDirectories = [file.deletingLastPathComponent()]
                } else if snapshot.savePath == nil, let file = transfer.workingFile {
                    // aria2 刚恢复的暂停任务尚未初始化文件列表，不能丢掉续传路径。
                    snapshot.savePath = file
                    snapshot.name = file.lastPathComponent
                    snapshot.writeDirectories = [transfer.directory]
                }
            }
            if let file = finalizedFiles[snapshot.engineTaskID] {
                snapshot.savePath = file
                snapshot.name = file.lastPathComponent
                snapshot.writeDirectories = [file.deletingLastPathComponent()]
            }
            return snapshot
        }
        let present = Set(snapshots.map(\.engineTaskID))
        // aria2 不会把已完成结果写进 session；尚未移动的成品仍需在重启后交给 App 校验和移动。
        for (id, transfer) in incompleteTransfers where !present.contains(id) {
            guard let bytes = transfer.downloadedBytes, let file = transfer.recoveryFile else { continue }
            snapshots.append(EngineTaskSnapshot(
                engineTaskID: id, name: file.lastPathComponent, totalBytes: bytes, receivedBytes: bytes,
                downloadRate: 0, uploadRate: 0, status: .completed, connections: 0,
                savePath: file, sourceURL: nil, errorMessage: nil,
                writeDirectories: [file.deletingLastPathComponent()]
            ))
        }
        if changed { try saveIncompleteTransfers() }
        return snapshots
    }

    /// 调用方在网页检查和显式校验通过后调用；旧任务直接返回原路径。
    public func finalizeIncomplete(_ id: String, file: URL) throws -> URL {
        guard var transfer = incompleteTransfers[id] else { return file }
        if let completed = transfer.completedFile {
            try transfer.cleanup()
            finalizedFiles[id] = completed
            incompleteTransfers[id] = nil
            try saveIncompleteTransfers()
            return completed
        }
        let workingFile = transfer.workingFile ?? file
        try transfer.planMove(from: workingFile)
        incompleteTransfers[id] = transfer
        try saveIncompleteTransfers()
        let destination = try transfer.finishMove(from: workingFile)
        finalizedFiles[id] = destination
        incompleteTransfers[id] = nil
        try saveIncompleteTransfers()
        try transfer.cleanup()
        return destination
    }

    /// 删除记录不会删除下载内容；彻底清理文件时把整个工作目录移到废纸篓。
    private func discardIncomplete(_ id: String, deleteFiles: Bool) throws {
        if deleteFiles, let directory = incompleteTransfers[id]?.directory,
           FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.trashItem(at: directory, resultingItemURL: nil)
        }
        incompleteTransfers[id] = nil
        finalizedFiles[id] = nil
        try saveIncompleteTransfers()
    }

    private func trashFiles(for status: Aria2RPCModels.Status) throws {
        if let file = finalizedFiles[status.gid], FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.trashItem(at: file, resultingItemURL: nil)
        } else if incompleteTransfers[status.gid] == nil {
            try Aria2FileSafety.trashFiles(for: status)
        }
    }

    /// 彻底删除或过期只清理引擎记录，保留用户文件。
    public func forgetTransfer(_ id: String) async throws {
        if let starting { try await starting.value }
        if client == nil {
            let record = stateDirectory.appendingPathComponent("incomplete.json")
            guard FileManager.default.fileExists(atPath: record.path) else { return }
            incompleteTransfers = try JSONDecoder().decode([String: IncompleteHTTPTransfer].self, from: Data(contentsOf: record))
        }
        incompleteTransfers[id] = nil
        finalizedFiles[id] = nil
        try saveIncompleteTransfers()
        guard let client else { return }
        do {
            let _: String = try await client.call("aria2.removeDownloadResult", [.string(id)])
        } catch let error as EngineError {
            guard case .rpc(let code, _) = error, code == 1 else { throw error }
        }
    }

    private func rekeyIncomplete(
        _ old: String, to new: String, transfer: IncompleteHTTPTransfer?, restarting: Bool = false
    ) throws {
        guard var transfer else { return }
        if restarting { transfer.restart() }
        incompleteTransfers[old] = nil
        incompleteTransfers[new] = transfer
        try saveIncompleteTransfers()
    }

    private func saveIncompleteTransfers() throws {
        try JSONEncoder().encode(incompleteTransfers).write(
            to: stateDirectory.appendingPathComponent("incomplete.json"), options: .atomic
        )
    }

    private func runningClient() throws -> Aria2RPCClient {
        guard stopping == nil, let client, process?.isRunning == true else {
            throw EngineError.notRunning
        }
        return client
    }

    private func taskStatus(_ id: String, using client: Aria2RPCClient) async throws -> Aria2RPCModels.Status {
        try await client.call("aria2.tellStatus", [
            .string(id), .array(Aria2RPCModels.Status.keys.map { .string($0) })
        ])
    }

    private func launch(options: EngineOptions) async throws {
        var configuration = Aria2Configuration(
            stateDirectory: stateDirectory, port: try Aria2Process.availablePort(),
            secret: Aria2Configuration.makeSecret(), options: options
        )
        configuration.proxy = proxyProvider()
        try configuration.prepareStateDirectory()
        try configuration.protectStateFiles()
        let record = stateDirectory.appendingPathComponent("incomplete.json")
        if FileManager.default.fileExists(atPath: record.path) {
            incompleteTransfers = try JSONDecoder().decode([String: IncompleteHTTPTransfer].self, from: Data(contentsOf: record))
        }
        let binary = try Aria2BinaryLocator.locate(explicitURL: binaryURL)
        try await prepareSessionCredentials(configuration.sessionURL)
        try configuration.write()
        let rpc = try Aria2RPCClient(port: configuration.port, secret: configuration.secret)
        let child: Aria2Process
        do {
            child = try Aria2Process(binary: binary, configuration: configuration) { [weak self] id in
                Task { await self?.didExit(id) }
            }
        } catch {
            throw EngineError.launchFailed(error.localizedDescription + "\n" + logTail(configuration.logURL))
        }
        self.configuration = configuration
        process = child
        do {
            // Race the whole readiness operation against one absolute five-second timeout.
            // Cancelling URLSession's child task also cancels any request still in flight.
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    var lastError = String(localized: "RPC 尚未就绪", bundle: .module)
                    while child.isRunning {
                        do {
                            let _: [String: Aria2RPCValue] = try await rpc.call("aria2.getVersion")
                            return
                        } catch {
                            lastError = String(describing: error)
                        }
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    throw EngineError.launchFailed(String(localized: "aria2 进程提前退出：\(lastError)", bundle: .module))
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(5))
                    throw EngineError.launchFailed(String(localized: "等待 aria2 RPC 就绪超时（5 秒）", bundle: .module))
                }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
            guard child.isRunning else { throw EngineError.launchFailed(String(localized: "aria2 进程提前退出", bundle: .module)) }
            // 先通过本机 RPC 下发凭据，再对调用方宣告启动完成；conf 始终不保存代理口令。
            let _: String = try await rpc.call("aria2.changeGlobalOption", [
                .object(configuration.proxy.aria2Options.mapValues(Aria2RPCValue.string))
            ])
            if configuration.proxy.credential != nil {
                var offset = 0
                while true {
                    let restored: [Aria2RPCModels.Status] = try await rpc.call("aria2.tellWaiting", [
                        .integer(offset), .integer(1000), .array([.string("gid"), .string("status")])
                    ])
                    for task in restored {
                        let _: String = try await rpc.call("aria2.changeOption", [
                            .string(task.gid), .object(configuration.proxy.aria2Options.mapValues(Aria2RPCValue.string))
                        ])
                    }
                    proxyRestoredTaskIDs.formUnion(restored.map(\.gid))
                    guard restored.count == 1000 else { break }
                    offset += restored.count
                }
            }
            client = rpc
            // 轮询不需要跨执行器管理系统回调，且随子进程退出取消。
            proxyMonitor = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) }
                    catch { return }
                    do { try await self?.refreshProxy() }
                    catch { Aria2Process.logger.warning("更新 HTTP 代理失败，请在网络设置中重新应用。") }
                }
            }
            permissionMonitor = Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        try configuration.protectStateFiles()
                        try await Task.sleep(for: .milliseconds(100))
                    } catch is CancellationError {
                        return
                    } catch {
                        // 目录仍是第一层保护；文件权限无法修复时停止写入敏感状态。
                        await self?.stop()
                        return
                    }
                }
            }
        } catch {
            await child.finish(grace: .zero)
            didExit(child.id)
            let reason: String
            if let failure = error as? EngineError, case .launchFailed(let message) = failure {
                reason = message
            } else {
                reason = String(describing: error)
            }
            throw EngineError.launchFailed(reason + "\n" + logTail(configuration.logURL))
        }
    }

    private static func requestContext(headers: [String]) -> DownloadRequestContext {
        var context = DownloadRequestContext()
        for header in headers {
            guard let colon = header.firstIndex(of: ":") else { continue }
            let name = String(header[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(header[header.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            context.headers[name] = value
        }
        return context
    }

    /// session 在子进程启动时就会恢复下载，必须在启动前处理其中的旧凭据。
    private func prepareSessionCredentials(_ file: URL) async throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let text = try String(contentsOf: file, encoding: .utf8)
        var entries: [[String]] = []
        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            if line.first?.isWhitespace != true { entries.append([line]) }
            else if !entries.isEmpty { entries[entries.count - 1].append(line) }
        }
        var changed = false
        for index in entries.indices {
            let headers = entries[index].dropFirst().compactMap { line -> String? in
                let value = line.trimmingCharacters(in: .whitespaces)
                return value.hasPrefix("header=") ? String(value.dropFirst(7)) : nil
            }
            let context = Self.requestContext(headers: headers)
            guard context.requestCookie != nil || context.headers.keys.contains(where: { ["authorization", "proxy-authorization"].contains($0.lowercased()) }),
                  let uri = entries[index].first?.split(whereSeparator: \.isWhitespace).first,
                  let url = URL(string: String(uri)) else { continue }
            let prepared = try await HTTPResourceProbe.prepareDownload(url, context: context)
            entries[index][0] = prepared.url.absoluteString
            entries[index].removeAll { line in
                let value = line.trimmingCharacters(in: .whitespaces)
                guard value.hasPrefix("header="), let colon = value.firstIndex(of: ":") else { return false }
                let name = value[value.index(value.startIndex, offsetBy: 7)..<colon].lowercased()
                return ["cookie", "authorization", "proxy-authorization"].contains(name)
            }
            for (name, value) in prepared.context.headers where ["cookie", "authorization", "proxy-authorization"].contains(name.lowercased()) {
                entries[index].append(" header=\(name): \(value)")
            }
            changed = true
        }
        if changed {
            let temporary = file.deletingLastPathComponent().appendingPathComponent(".session-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: temporary) }
            let data = Data((entries.map { $0.joined(separator: "\n") }.joined(separator: "\n") + "\n").utf8)
            try YtDlpCookieFile.writePrivate(data, to: temporary)
            _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary)
        }
    }

    private func shutdown() async {
        resumeAttempts.removeAll()
        guard let child = process else { return }
        let rpc = client
        client = nil
        if let rpc, child.isRunning {
            do {
                let results: [Aria2RPCModels.Status] = try await rpc.call("aria2.tellStopped", [.integer(0), .integer(1000)])
                for status in results where status.status == "complete" {
                    guard var transfer = incompleteTransfers[status.gid], let path = status.files?.first?.path,
                          transfer.completedFile == nil else { continue }
                    transfer.recordCompletion(file: URL(fileURLWithPath: path), bytes: status.completedLength.flatMap(Int64.init) ?? 0)
                    incompleteTransfers[status.gid] = transfer
                }
                try saveIncompleteTransfers()
            } catch {
                Aria2Process.logger.error("保存未完成文件记录失败：\(error.localizedDescription, privacy: .public)")
            }
            do {
                let _: String = try await rpc.call("aria2.saveSession")
                try configuration?.protectStateFiles()
            } catch {
                Aria2Process.logger.error("保存 aria2 会话失败：\(error.localizedDescription, privacy: .public)")
            }
        }
        // shutdown RPC 固定延迟三秒；SIGINT 直接进入同一正常关闭流程，
        // 仍由 aria2 刷新控制文件、磁盘缓存和最终 session，不强制结束下载。
        child.interrupt()
        await child.finish(grace: .seconds(3))
        try? configuration?.protectStateFiles()
        didExit(child.id)
    }

    private func didExit(_ id: UUID) {
        guard process?.id == id else { return }
        proxyMonitor?.cancel()
        proxyMonitor = nil
        proxyRestoredTaskIDs.removeAll()
        streamSelectors.removeAll()
        permissionMonitor?.cancel()
        permissionMonitor = nil
        try? configuration?.protectStateFiles()
        client = nil
        process = nil
    }

    private func logTail(_ url: URL) -> String {
        do {
            return HTTPProxyConfiguration.redacted(try String(contentsOf: url, encoding: .utf8))
                .split(separator: "\n").suffix(8).joined(separator: "\n")
        } catch {
            return String(localized: "无法读取 aria2.log：\(error.localizedDescription)", bundle: .module)
        }
    }
}
