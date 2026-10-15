import Darwin
import Foundation

/// 非阻塞 POSIX I/O：等待期间让出 actor，不阻塞协作线程，也不使用 GCD。
actor ECSocket {
    private var descriptor: Int32 = -1
    private var framer = ECFramer()
    private var packets: [ECPacket] = []

    deinit {
        if descriptor >= 0 { Darwin.close(descriptor) }
    }

    func connect(port: UInt16, deadline: ContinuousClock.Instant) async throws {
        disconnect()
        descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ECError.disconnected }
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { throw ECError.disconnected }
        var enabled: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw ECError.disconnected
        }
        var address = ECLoopback.address(port: port)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return }
        guard errno == EINPROGRESS else { throw ECError.disconnected }
        while true {
            try check(deadline)
            var item = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&item, 1, 0)
            guard ready >= 0 || errno == EINTR else { throw ECError.disconnected }
            if ready > 0 {
                var error: Int32 = 0
                var size = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
                    throw ECError.disconnected
                }
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func exchange(_ packet: ECPacket, deadline: ContinuousClock.Instant) async throws -> ECPacket {
        let data = try ECCodec.encode(packet)
        var offset = 0
        while offset < data.count {
            try check(deadline)
            let count = data.withUnsafeBytes {
                Darwin.send(descriptor, $0.baseAddress?.advanced(by: offset), data.count - offset, 0)
            }
            if count > 0 {
                offset += count
            } else if count < 0, [EAGAIN, EWOULDBLOCK, EINTR].contains(errno) {
                try await Task.sleep(for: .milliseconds(10))
            } else {
                throw ECError.disconnected
            }
        }
        while packets.isEmpty {
            try check(deadline)
            var bytes = [UInt8](repeating: 0, count: 64 * 1024)
            let count = Darwin.recv(descriptor, &bytes, bytes.count, 0)
            if count > 0 {
                packets.append(contentsOf: try framer.append(Data(bytes.prefix(count))))
            } else if count < 0, [EAGAIN, EWOULDBLOCK, EINTR].contains(errno) {
                try await Task.sleep(for: .milliseconds(10))
            } else {
                throw ECError.disconnected
            }
        }
        return packets.removeFirst()
    }

    func disconnect() {
        if descriptor >= 0 { Darwin.close(descriptor) }
        descriptor = -1
        framer = ECFramer()
        packets.removeAll()
    }

    private func check(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard descriptor >= 0 else { throw ECError.disconnected }
        guard ContinuousClock.now < deadline else { throw ECError.timeout }
    }
}
