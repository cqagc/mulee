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

    /// - Parameters:
    ///   - stateDirectory: 存放 aria2 配置、会话、日志的目录（App 传 Application Support/Mulee/aria2）。
    ///   - binaryURL: 指定 aria2c 路径；nil 时按 App 包内 Helpers、环境变量 MULEE_ARIA2C 依次查找。
    public init(stateDirectory: URL, binaryURL: URL? = nil) {
        self.stateDirectory = stateDirectory
        self.binaryURL = binaryURL
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
        checksum: DownloadChecksum? = nil, paused: Bool = false
    ) async throws -> String {
        let client = try runningClient()
        guard case .http(let url, _, _) = link,
              let scheme = url.scheme?.lowercased(), ["http", "https", "ftp"].contains(scheme) else {
            throw EngineError.unsupportedLink
        }
        var params: [Aria2RPCValue] = [.array([.string(url.absoluteString)])]
        var values = try Aria2RequestOptions.values(context: context, checksum: checksum)
        if let directory { values["dir"] = .string(directory.path) }
        if paused { values["pause"] = .string("true") }
        if !values.isEmpty { params.append(.object(values)) }
        return try await client.call("aria2.addUri", params)
    }

    /// 保留任务路径与控制文件，停态 GID 先重建为暂停任务，再用 changeUri 换链。
    public func replaceURI(
        _ engineTaskID: String, with url: URL, context: DownloadRequestContext,
        checksum: DownloadChecksum?, restartFromScratch: Bool = false
    ) async throws -> String {
        let client = try runningClient()
        var status = try await taskStatus(engineTaskID, using: client)
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
        var context = context
        if let path = status.files?.first?.path, !path.isEmpty {
            context.suggestedFilename = URL(fileURLWithPath: path).lastPathComponent
        }
        var values = try Aria2RequestOptions.values(context: context, checksum: checksum)
        if let directory = status.dir { values["dir"] = .string(directory) }
        values["pause"] = .string("true")
        values["auto-file-renaming"] = .string("false")
        values["continue"] = .string(restartFromScratch ? "false" : "true")
        let previousURIs = status.files?.first?.uris?.map(\.uri) ?? []
        var id = engineTaskID
        if restartFromScratch {
            try await remove(engineTaskID, deleteFiles: true)
            return try await client.call("aria2.addUri", [.array([.string(url.absoluteString)]), .object(values)])
        }
        if ["error", "complete", "removed"].contains(status.status) {
            // aria2 的 changeUri 不接受 stopped 结果；同路径加载 .aria2 分块进度。
            let old = previousURIs.first ?? url.absoluteString
            id = try await client.call("aria2.addUri", [.array([.string(old)]), .object(values)])
            do {
                let _: String = try await client.call("aria2.removeDownloadResult", [.string(engineTaskID)])
            } catch {
                try? await remove(id, deleteFiles: false)
                throw error
            }
        } else {
            try await pause(id)
            var updated = try Aria2RequestOptions.values(context: context, checksum: checksum)
            updated.removeValue(forKey: "out")
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
        return id
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
            try await remove(engineTaskID, deleteFiles: false)
            return try await client.call("aria2.addUri", [.array([.string(uri)]), .object(updated)])
        }
        let _: String = try await client.call("aria2.changeOption", [
            .string(engineTaskID), .object(["checksum": .string(checksum.aria2Value)])
        ])
        return engineTaskID
    }

    public func pause(_ engineTaskID: String) async throws {
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
        let _: String = try await client.call("aria2.unpause", [.string(engineTaskID)])
    }

    public func remove(_ engineTaskID: String, deleteFiles: Bool) async throws {
        let client = try runningClient()
        var status = try await taskStatus(engineTaskID, using: client)
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
                    if deleteFiles { try Aria2FileSafety.trashFiles(for: status) }
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
        if deleteFiles { try Aria2FileSafety.trashFiles(for: status) }
    }

    public func snapshots() async throws -> [EngineTaskSnapshot] {
        let client = try runningClient()
        let keys = Aria2RPCValue.array(Aria2RPCModels.Status.keys.map { .string($0) })
        let active: [Aria2RPCModels.Status] = try await client.call("aria2.tellActive", [keys])
        let waiting: [Aria2RPCModels.Status] = try await client.call(
            "aria2.tellWaiting", [.integer(0), .integer(1000), keys]
        )
        let stopped: [Aria2RPCModels.Status] = try await client.call(
            "aria2.tellStopped", [.integer(0), .integer(1000), keys]
        )
        return (active + waiting + stopped).compactMap(Aria2StatusMapper.snapshot)
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
        let binary = try Aria2BinaryLocator.locate(explicitURL: binaryURL)
        let configuration = Aria2Configuration(
            stateDirectory: stateDirectory, port: try Aria2Process.availablePort(),
            secret: Aria2Configuration.makeSecret(), options: options
        )
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
            client = rpc
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

    private func shutdown() async {
        guard let child = process else { return }
        let rpc = client
        client = nil
        if let rpc, child.isRunning {
            do {
                let _: String = try await rpc.call("aria2.saveSession")
            } catch {
                Aria2Process.logger.error("保存 aria2 会话失败：\(error.localizedDescription, privacy: .public)")
            }
        }
        // shutdown RPC 固定延迟三秒；SIGINT 直接进入同一正常关闭流程，
        // 仍由 aria2 刷新控制文件、磁盘缓存和最终 session，不强制结束下载。
        child.interrupt()
        await child.finish(grace: .seconds(3))
        didExit(child.id)
    }

    private func didExit(_ id: UUID) {
        guard process?.id == id else { return }
        client = nil
        process = nil
    }

    private func logTail(_ url: URL) -> String {
        do {
            return try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n").suffix(8).joined(separator: "\n")
        } catch {
            return String(localized: "无法读取 aria2.log：\(error.localizedDescription)", bundle: .module)
        }
    }
}
