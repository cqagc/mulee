import Darwin
import Foundation
import OSLog

struct Aria2Process: Sendable {
    let id = UUID()
    private let process: Process
    static let logger = Logger(subsystem: "MuleeCore", category: "Aria2")

    init(binary: URL, configuration: Aria2Configuration, onExit: @escaping @Sendable (UUID) -> Void) throws {
        let process = Process()
        self.process = process
        // 下载成品继承用户 umask；敏感状态由独立的 0700 目录保护。
        try configuration.prepareStateDirectory()
        try configuration.protectStateFiles()
        process.executableURL = binary
        process.arguments = configuration.arguments
        var environment = ProcessInfo.processInfo.environment
        environment["LANG"] = "en_US.UTF-8"
        environment["LC_ALL"] = "en_US.UTF-8"
        environment["no_proxy"] = configuration.proxy.aria2Options["no-proxy"] ?? "localhost,127.0.0.1,::1"
        environment["NO_PROXY"] = configuration.proxy.aria2Options["no-proxy"] ?? "localhost,127.0.0.1,::1"
        // 环境代理不能覆盖用户选择的直连或手动设置。
        for key in ["http_proxy", "https_proxy", "ftp_proxy", "all_proxy", "HTTP_PROXY", "HTTPS_PROXY", "FTP_PROXY", "ALL_PROXY"] {
            environment.removeValue(forKey: key)
        }
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let id = self.id
        process.terminationHandler = { _ in onExit(id) }
        try process.run()
    }

    var isRunning: Bool { process.isRunning }

    func interrupt() {
        if process.isRunning { kill(process.processIdentifier, SIGINT) }
    }

    func finish(grace: Duration) async {
        // 独立清理任务避免调用方取消时跳过保存等待或遗留子进程。
        await Task.detached { [process] in
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: grace)
            while process.isRunning && clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(25))
            }
            if process.isRunning { process.terminate() }
            let terminationDeadline = clock.now.advanced(by: .seconds(1))
            while process.isRunning && clock.now < terminationDeadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            while process.isRunning { try? await Task.sleep(for: .milliseconds(10)) }
        }.value
    }

    static func availablePort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard named == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        return UInt16(bigEndian: address.sin_port)
    }
}
