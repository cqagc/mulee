import Foundation

/// EC 无请求 ID；锁覆盖连接、认证和整次请求，避免 actor 在 await 时交错读写。
actor ECClient {
    private let port: UInt16
    private let password: String
    private let timeout: Duration
    private var socket: ECSocket?
    private var busy = false
    private(set) var generation = UUID()

    init(port: UInt16, password: String, timeout: Duration = .seconds(10)) {
        self.port = port
        self.password = password
        self.timeout = timeout
    }

    func connect(deadline: ContinuousClock.Instant? = nil) async throws {
        try await lock()
        defer { busy = false }
        try await ensureConnected(deadline: deadline ?? ContinuousClock.now.advanced(by: timeout))
    }

    func request(_ packet: ECPacket) async throws -> ECPacket {
        try await lock()
        defer { busy = false }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        do {
            try await ensureConnected(deadline: deadline)
            guard let socket else { throw ECError.disconnected }
            return try await socket.exchange(packet, deadline: deadline)
        } catch {
            await socket?.disconnect()
            socket = nil
            // 不重放可能已执行的 add/delete；下一请求自动重连并重新认证。
            throw error
        }
    }

    func disconnect() async {
        // 关闭也排在当前请求之后，避免旧请求误关刚重连的 socket。
        while busy {
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
        }
        busy = true
        defer { busy = false }
        await socket?.disconnect()
        socket = nil
    }

    private func lock() async throws {
        while busy { try await Task.sleep(for: .milliseconds(10)) }
        try Task.checkCancellation()
        busy = true
    }

    private func ensureConnected(deadline: ContinuousClock.Instant) async throws {
        if socket != nil { return }
        let candidate = ECSocket()
        do {
            try await candidate.connect(port: port, deadline: deadline)
            let challenge = try await candidate.exchange(ECPacket(opcode: ECCode.Op.authRequest, tags: [
                .string(ECCode.Tag.clientName, "Mulee"),
                .string(ECCode.Tag.clientVersion, "1.0"),
                .number(ECCode.Tag.protocolVersion, 0x0204)
            ]), deadline: deadline)
            guard challenge.opcode == ECCode.Op.authSalt,
                  let salt = challenge.tag(ECCode.Tag.passwordSalt)?.number else { throw ECError.authentication }
            let proof = ECTag(name: ECCode.Tag.passwordHash, type: 9,
                              data: ECAuthentication.response(password: password, salt: salt))
            let accepted = try await candidate.exchange(
                ECPacket(opcode: ECCode.Op.authPassword, tags: [proof]), deadline: deadline
            )
            guard accepted.opcode == ECCode.Op.authOK else { throw ECError.authentication }
            socket = candidate
            generation = UUID()
        } catch {
            await candidate.disconnect()
            throw error
        }
    }
}
