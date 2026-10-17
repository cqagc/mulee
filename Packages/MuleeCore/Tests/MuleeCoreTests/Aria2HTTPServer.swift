import Foundation
import Network

/// Test-only static HTTP server. Network.framework requires a callback executor;
/// all request handling, throttling and mutable state use Swift tasks and this actor.
actor Aria2HTTPServer {
    private let listener: NWListener
    private let payload: Data
    private var connections: [UUID: NWConnection] = [:]
    private var requests: [UUID: Task<Void, Never>] = [:]
    private var failure: NWError?
    private var ready = false
    private(set) var rangeRequests = 0
    private(set) var receivedHeaders: [[String: String]] = []
    private var stopped = false
    private var redirect: URL?
    private var holdsHEAD = false
    private var headWaiters: [CheckedContinuation<Void, Never>] = []

    var suspendedHEADRequests: Int { headWaiters.count }

    func holdHEADRequests() {
        holdsHEAD = true
    }

    func releaseHEADRequests() {
        holdsHEAD = false
        let waiting = headWaiters
        headWaiters.removeAll()
        for continuation in waiting { continuation.resume() }
    }

    func setRedirect(_ url: URL?) {
        redirect = url
    }

    init(payload: Data) throws {
        self.payload = payload
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        self.listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        listener.stateUpdateHandler = { [weak self] state in
            Task { await self?.update(state) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        listener.start(queue: .main)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !ready {
            if let failure { throw failure }
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let port = listener.port else { throw URLError(.cannotConnectToHost) }
        return port.rawValue
    }

    func stop() async {
        stopped = true
        releaseHEADRequests()
        listener.cancel()
        let tasks = Array(requests.values)
        for task in tasks { task.cancel() }
        for connection in connections.values { connection.cancel() }
        for task in tasks { await task.value }
        requests.removeAll()
        connections.removeAll()
    }

    private func update(_ state: NWListener.State) {
        switch state {
        case .ready: ready = true
        case .failed(let error): failure = error
        default: break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped else {
            connection.cancel()
            return
        }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .main)
        requests[id] = Task {
            do { try await serve(connection) } catch {
                // Pause/remove closes the socket while a response is being sent.
                // Unexpected errors are retained and checked by the integration test.
                if !Task.isCancelled, let networkError = error as? NWError,
                   networkError != .posix(.ECANCELED), networkError != .posix(.ECONNRESET),
                   networkError != .posix(.EPIPE), networkError != .posix(.ENOTCONN) {
                    failure = networkError
                }
            }
            connection.cancel()
            connections[id] = nil
            requests[id] = nil
        }
    }

    func checkFailure() throws {
        if let failure { throw failure }
    }

    private func serve(_ connection: NWConnection) async throws {
        var request = Data()
        while request.range(of: Data("\r\n\r\n".utf8)) == nil {
            let part = try await receive(connection)
            guard !part.isEmpty, request.count < 16_384 else { throw URLError(.badServerResponse) }
            request.append(part)
        }
        let lines = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n")
        let first = lines.first?.split(separator: " ") ?? []
        guard first.count >= 2 else { throw URLError(.badServerResponse) }
        let path = String(first[1])
        let headers = Dictionary(lines.dropFirst().compactMap { line -> (String, String)? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return (String(line[..<colon]).lowercased(), String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
        }, uniquingKeysWith: { _, new in new })
        receivedHeaders.append(headers)
        if first[0] == "HEAD", holdsHEAD {
            await withCheckedContinuation { headWaiters.append($0) }
        }
        if let redirect {
            try await send(Data("HTTP/1.1 302 Found\r\nLocation: \(redirect.absoluteString)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), on: connection)
            return
        }
        for code in [401, 403, 410] where path == "/status-\(code).bin" {
            try await send(Data("HTTP/1.1 \(code) Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), on: connection)
            return
        }
        if path == "/auth.bin", headers["authorization"] != "Basic " + Data("user:password".utf8).base64EncodedString() {
            try await send(Data("HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"example\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), on: connection)
            return
        }
        if path == "/page.bin" {
            let body = "<!doctype html><html>Login</html>"
            try await send(Data("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n".utf8), on: connection)
            if first[0] != "HEAD" { try await send(Data(body.utf8), on: connection) }
            return
        }
        if path == "/missing.bin" {
            try await send(Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), on: connection)
            return
        }
        var lower = 0
        var upper = payload.count - 1
        let range = lines.first { $0.lowercased().hasPrefix("range: bytes=") }
        if let range {
            rangeRequests += 1
            let pieces = range.dropFirst("range: bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
            lower = pieces.first.flatMap { Int($0) } ?? 0
            if pieces.count > 1, let end = Int(pieces[1]) { upper = min(upper, end) }
        }
        guard lower >= 0, lower <= upper, upper < payload.count else {
            try await send(Data("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), on: connection)
            return
        }
        let status = range == nil ? "200 OK" : "206 Partial Content"
        var header = "HTTP/1.1 \(status)\r\nContent-Length: \(upper - lower + 1)\r\nAccept-Ranges: bytes\r\n"
        if range != nil { header += "Content-Range: bytes \(lower)-\(upper)/\(payload.count)\r\n" }
        header += "ETag: \"payload-v1\"\r\nContent-Type: application/octet-stream\r\nConnection: close\r\n\r\n"
        try await send(Data(header.utf8), on: connection)
        if first[0] == "HEAD" { return }
        var offset = lower
        while offset <= upper {
            try Task.checkCancellation()
            let end = min(offset + 32_768, upper + 1)
            try await send(payload.subdata(in: offset..<end), on: connection)
            offset = end
            if path.hasPrefix("/slow") { try await Task.sleep(for: .milliseconds(40)) }
        }
    }

    private func receive(_ connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: data ?? Data()) }
            }
        }
    }

    private func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }
}
