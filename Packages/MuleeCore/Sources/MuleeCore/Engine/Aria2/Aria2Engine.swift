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
        updated.options = options
        // Validate before changing the running process; disk-cache is startup-only.
        _ = try updated.contents()
        let values = updated.runtimeOptions.mapValues { Aria2RPCValue.string($0) }
        let _: String = try await client.call("aria2.changeGlobalOption", [.object(values)])
        try updated.write()
        configuration = updated
    }

    public func add(link: ParsedLink, directory: URL?) async throws -> String {
        try await add(link: link, directory: directory, paused: false)
    }

    public func addQueued(link: ParsedLink, directory: URL?) async throws -> String {
        try await add(link: link, directory: directory, paused: true)
    }

    private func add(link: ParsedLink, directory: URL?, paused: Bool) async throws -> String {
        let client = try runningClient()
        guard case .http(let url, _, _) = link,
              let scheme = url.scheme?.lowercased(), ["http", "https", "ftp"].contains(scheme) else {
            throw EngineError.unsupportedLink
        }
        var params: [Aria2RPCValue] = [.array([.string(url.absoluteString)])]
        var values: [String: Aria2RPCValue] = [:]
        if let directory { values["dir"] = .string(directory.path) }
        if paused { values["pause"] = .string("true") }
        if !values.isEmpty { params.append(.object(values)) }
        return try await client.call("aria2.addUri", params)
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
                status = try await taskStatus(engineTaskID, using: client)
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
            do {
                let _: String = try await rpc.call("aria2.shutdown")
            } catch {
                Aria2Process.logger.error("请求 aria2 退出失败：\(error.localizedDescription, privacy: .public)")
            }
        }
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
