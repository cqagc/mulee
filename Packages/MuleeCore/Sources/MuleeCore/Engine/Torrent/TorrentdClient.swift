import Foundation

/// 一次 torrentd 会话；所有 continuation 都只由本 actor 恢复一次。
actor TorrentdClient {
    nonisolated let events: AsyncStream<TorrentdEvent>
    private let eventContinuation: AsyncStream<TorrentdEvent>.Continuation
    private let transport: any TorrentdTransport
    private let requestTimeout: Duration
    private var reader: Task<Void, Never>?
    private var active = false
    private var ready = false
    private var nextID = 0
    private var pending: [Int: TorrentdPending<TorrentdValue>] = [:]
    private var readyWaiters: [UUID: TorrentdPending<Void>] = [:]
    private var buffer = Data()
    private static let maximumLineLength = 16 * 1_024 * 1_024

    init(transport: any TorrentdTransport, requestTimeout: Duration = .seconds(10)) {
        self.transport = transport
        self.requestTimeout = requestTimeout
        (events, eventContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(128))
    }

    func start() async throws {
        guard reader == nil else { return }
        let output = try await transport.start()
        active = true
        reader = Task { [weak self] in
            for await chunk in output {
                guard !Task.isCancelled else { break }
                await self?.receive(chunk)
            }
            await self?.didExit()
        }
    }

    func isRunning() async -> Bool {
        guard active else { return false }
        return await transport.isRunning()
    }

    func waitUntilReady(timeout: Duration = .seconds(15)) async throws {
        guard active else { throw EngineError.notRunning }
        if ready { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                let timer = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    await self?.failReady(id, error: EngineError.launchFailed("等待 BT 引擎就绪超时"))
                }
                readyWaiters[id] = TorrentdPending(continuation: continuation, timeout: timer)
            }
        } onCancel: {
            Task { await self.failReady(id, error: CancellationError()) }
        }
    }

    func call<Parameters: Encodable & Sendable, Result: Decodable & Sendable>(
        _ method: String,
        _ params: Parameters,
        as type: Result.Type = Result.self
    ) async throws -> Result {
        guard active, ready else { throw EngineError.notRunning }
        nextID += 1
        let id = nextID
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        var data = try encoder.encode(TorrentdRequest(id: id, method: method, params: params))
        data.append(10)
        let requestData = data
        let value: TorrentdValue = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let timer = Task { [weak self, requestTimeout] in
                    do { try await Task.sleep(for: requestTimeout) } catch { return }
                    await self?.fail(id, error: EngineError.rpc(code: -1, message: "BT 引擎响应超时"))
                }
                pending[id] = TorrentdPending(continuation: continuation, timeout: timer)
                Task { [weak self, transport] in
                    do { try await transport.send(requestData) } catch {
                        await self?.fail(id, error: error)
                    }
                }
            }
        } onCancel: {
            Task { await self.fail(id, error: CancellationError()) }
        }
        do {
            return try Self.decoder().decode(type, from: JSONEncoder().encode(value))
        } catch {
            throw EngineError.invalidResponse("BT 引擎返回的数据不完整")
        }
    }

    func finish(grace: Duration = .seconds(10), terminationGrace: Duration = .seconds(5)) async {
        await transport.finish(grace: grace, terminationGrace: terminationGrace)
        reader?.cancel()
        reader = nil
        didExit()
    }

    private func receive(_ chunk: Data) {
        guard active else { return }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer[..<newline]
            guard line.count <= Self.maximumLineLength else {
                didExit(error: EngineError.invalidResponse("BT 引擎返回的消息过长"))
                return
            }
            buffer.removeSubrange(...newline)
            if line.isEmpty { continue }
            do {
                let value = try Self.decoder().decode(TorrentdValue.self, from: Data(line))
                guard case .object(let object) = value else {
                    throw EngineError.invalidResponse("BT 引擎消息格式有误")
                }
                if object["event"] != nil {
                    let event = try Self.decoder().decode(TorrentdEvent.self, from: Data(line))
                    if event.event == "ready" {
                        ready = true
                        for waiter in readyWaiters.values {
                            waiter.timeout.cancel()
                            waiter.continuation.resume()
                        }
                        readyWaiters.removeAll()
                    }
                    eventContinuation.yield(event)
                    if event.event == "fatal" {
                        didExit(error: EngineError.launchFailed("BT 引擎无法启动，请检查状态目录是否被占用及访问权限"))
                    }
                } else {
                    let response = try Self.decoder().decode(TorrentdResponse.self, from: Data(line))
                    guard let request = pending.removeValue(forKey: response.id) else { continue }
                    request.timeout.cancel()
                    if let error = response.error {
                        request.continuation.resume(throwing: TorrentErrorDescriptions.error(for: error.code))
                    } else if let result = response.result {
                        request.continuation.resume(returning: result)
                    } else {
                        request.continuation.resume(throwing: EngineError.invalidResponse("BT 引擎响应缺少结果"))
                    }
                }
            } catch {
                didExit(error: EngineError.invalidResponse("无法解析 BT 引擎消息"))
                return
            }
        }
        if buffer.count > Self.maximumLineLength {
            didExit(error: EngineError.invalidResponse("BT 引擎返回的消息过长"))
        }
    }

    private func fail(_ id: Int, error: any Error) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeout.cancel()
        request.continuation.resume(throwing: error)
    }

    private func failReady(_ id: UUID, error: any Error) {
        guard let waiter = readyWaiters.removeValue(forKey: id) else { return }
        waiter.timeout.cancel()
        waiter.continuation.resume(throwing: error)
    }

    private func didExit(error: any Error = EngineError.notRunning) {
        active = false
        ready = false
        buffer.removeAll()
        for id in pending.keys { fail(id, error: error) }
        for id in readyWaiters.keys { failReady(id, error: error) }
        eventContinuation.finish()
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
