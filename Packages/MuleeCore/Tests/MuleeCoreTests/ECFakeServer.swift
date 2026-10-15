import CryptoKit
import Darwin
import Foundation
@testable import MuleeCore

/// 真实回环 TCP 假服务端；挑战值固定，测试可独立核对 MD5 结果。
actor ECFakeServer {
    let port: UInt16
    private let listener: Int32
    private let password: String
    private let rejectAuthentication: Bool
    private let hangRequests: Bool
    private let closeAfterReply: Bool
    private var connection: Int32 = -1
    private var loop: Task<Void, any Error>?
    private(set) var requests: [ECPacket] = []
    private(set) var authentications = 0

    init(password: String = "密碼-test", rejectAuthentication: Bool = false, hangRequests: Bool = false, closeAfterReply: Bool = false) throws {
        self.password = password
        self.rejectAuthentication = rejectAuthentication
        self.hangRequests = hangRequests
        self.closeAfterReply = closeAfterReply
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ECError.disconnected }
        var address = ECLoopback.address(port: 0)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }
        guard bound == 0, named == 0, listen(fd, 4) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            close(fd)
            throw ECError.disconnected
        }
        listener = fd
        port = UInt16(bigEndian: address.sin_port)
    }

    func start() { loop = Task { try await serve() } }

    func stop() async throws {
        loop?.cancel()
        if let loop {
            do { try await loop.value } catch is CancellationError { }
        }
        if connection >= 0 { close(connection) }
        close(listener)
        connection = -1
        loop = nil
    }

    private func serve() async throws {
        while !Task.isCancelled {
            let fd = accept(listener, nil, nil)
            if fd < 0 {
                try await Task.sleep(for: .milliseconds(2))
                continue
            }
            connection = fd
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            var yes: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            do { try await session(fd) } catch ECError.disconnected { }
            close(fd)
            connection = -1
        }
    }

    private func session(_ fd: Int32) async throws {
        var framer = ECFramer()
        var phase = 0
        while true {
            try Task.checkCancellation()
            var bytes = [UInt8](repeating: 0, count: 65536)
            let length = recv(fd, &bytes, bytes.count, 0)
            if length == 0 { return }
            if length < 0 {
                guard [EWOULDBLOCK, EAGAIN, EINTR].contains(errno) else { throw ECError.disconnected }
                try await Task.sleep(for: .milliseconds(2))
                continue
            }
            for packet in try framer.append(Data(bytes.prefix(length))) {
                requests.append(packet)
                if phase == 0 {
                    guard packet.opcode == ECCode.Op.authRequest else { throw ECError.authentication }
                    try await send(ECPacket(opcode: ECCode.Op.authSalt, tags: [.number(ECCode.Tag.passwordSalt, 0xABCDEF123456)]), fd: fd)
                    phase = 1
                } else if phase == 1 {
                    let md5: (String) -> String = { text in
                        Insecure.MD5.hash(data: Data(text.utf8)).map {
                            let byte = String($0, radix: 16)
                            return byte.count == 1 ? "0" + byte : byte
                        }.joined()
                    }
                    let expected = Data(Insecure.MD5.hash(data: Data((md5(password) + md5("ABCDEF123456")).utf8)))
                    let accepted = !rejectAuthentication && packet.opcode == ECCode.Op.authPassword
                        && packet.tag(ECCode.Tag.passwordHash)?.data == expected
                    try await send(ECPacket(opcode: accepted ? ECCode.Op.authOK : ECCode.Op.authFail), fd: fd)
                    if !accepted { return }
                    authentications += 1
                    phase = 2
                } else if !hangRequests {
                    try await send(ECPacket(opcode: ECCode.Op.noop, tags: packet.tags), fd: fd)
                    if closeAfterReply { return }
                }
            }
        }
    }

    private func send(_ packet: ECPacket, fd: Int32) async throws {
        let data = try ECCodec.encode(packet)
        // 故意拆成 1 字节和剩余字节，覆盖真实 TCP 分片。
        for fragment in [Data(data.prefix(1)), Data(data.dropFirst())] {
            var sent = 0
            while sent < fragment.count {
                try Task.checkCancellation()
                let count = fragment.withUnsafeBytes { Darwin.send(fd, $0.baseAddress?.advanced(by: sent), fragment.count - sent, 0) }
                if count > 0 { sent += count } else if count < 0, [EWOULDBLOCK, EAGAIN, EINTR].contains(errno) {
                    try await Task.sleep(for: .milliseconds(2))
                } else { throw ECError.disconnected }
            }
            await Task.yield()
        }
    }
}
