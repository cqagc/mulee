import Foundation
@testable import MuleeCore

/// 内存中实现 JSON Lines；可手动响应、模拟退出和记录所有协议参数。
actor TorrentFakeTransport: TorrentdTransport {
    nonisolated let requests: AsyncStream<TorrentTestRequest>
    private let requestContinuation: AsyncStream<TorrentTestRequest>.Continuation
    private let output: AsyncStream<Data>
    private let outputContinuation: AsyncStream<Data>.Continuation
    private let sendsReady: Bool
    private let automaticReplies: Bool
    private var running = false
    private(set) var sent: [TorrentTestRequest] = []
    private(set) var startCount = 0
    private(set) var finishCount = 0
    private(set) var addedTorrent: Data?
    private var results: [String: TorrentdValue] = [:]

    init(sendsReady: Bool = true, automaticReplies: Bool = true) {
        self.sendsReady = sendsReady
        self.automaticReplies = automaticReplies
        (requests, requestContinuation) = AsyncStream.makeStream()
        (output, outputContinuation) = AsyncStream.makeStream()
    }

    func start() -> AsyncStream<Data> {
        startCount += 1
        running = true
        if sendsReady { emit(Data("{\"event\":\"ready\",\"version\":\"0.1.0\",\"listen_port\":6881}\n".utf8)) }
        return output
    }

    func send(_ data: Data) throws {
        guard running else { throw EngineError.notRunning }
        let request = try JSONDecoder().decode(TorrentTestRequest.self, from: data)
        sent.append(request)
        requestContinuation.yield(request)
        if request.method == "add", case .string(let path) = request.parameters["torrent_file"] {
            addedTorrent = try Data(contentsOf: URL(fileURLWithPath: path))
        }
        guard automaticReplies else { return }
        let result: TorrentdValue
        if let configured = results[request.method] {
            result = configured
        } else {
            switch request.method {
            case "configure": result = .object(["listen_port": .integer(6881)])
            case "list": result = .object(["torrents": .array([])])
            case "files": result = .object(["files": .array([])])
            case "session_status":
                result = .object([
                    "listen_port": .integer(6881), "dht_nodes": .integer(42),
                    "has_incoming_connections": .bool(true), "download_rate": .integer(123),
                    "upload_rate": .integer(456), "external_address": .null
                ])
            case "add":
                result = .object(["id": .string(TorrentFixtures.id), "name": .string("Ubuntu"), "duplicate": .bool(false)])
            default: result = .object([:])
            }
        }
        try reply(request, result: result)
        if request.method == "shutdown" { crash() }
    }

    func setResult(_ method: String, _ value: TorrentdValue) {
        results[method] = value
    }

    func reply(_ request: TorrentTestRequest, result: TorrentdValue) throws {
        var data = try JSONEncoder().encode(TorrentdResponse(id: request.id, result: result, error: nil))
        data.append(10)
        emit(data)
    }

    func emit(_ data: Data) { outputContinuation.yield(data) }

    func crash() {
        running = false
        outputContinuation.finish()
    }

    func isRunning() -> Bool { running }

    func finish(grace: Duration, terminationGrace: Duration) {
        finishCount += 1
        crash()
    }
}
