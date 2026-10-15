import Darwin
import Foundation
import OSLog

/// 长期状态由 Ed2kEngine actor 持有；Process 自身提供线程安全的 isRunning。
struct Ed2kProcess: Sendable {
    private let process: Process
    let identity: Ed2kProcessIdentity
    static let logger = Logger(subsystem: "MuleeCore", category: "Ed2k")

    init(binary: URL, stateDirectory: URL) throws {
        let child = Process()
        child.executableURL = binary
        child.arguments = ["--config-dir", stateDirectory.path, "--log-stdout"]
        var environment = ProcessInfo.processInfo.environment
        environment["LANG"] = "en_US.UTF-8"
        environment["LC_ALL"] = "en_US.UTF-8"
        environment["HOME"] = stateDirectory.path
        child.environment = environment
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        guard let identity = Ed2kProcessIdentity.read(child.processIdentifier) else {
            if child.isRunning { child.terminate() }
            throw EngineError.launchFailed("无法核验电驴子进程身份")
        }
        process = child
        self.identity = identity
    }

    var isRunning: Bool { process.isRunning }

    func finish() async {
        // 即使 stop 的调用方取消，也要完成退出和回收。
        await Task.detached { [process] in
            if process.isRunning { process.terminate() }
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while process.isRunning && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(25))
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            while process.isRunning { try? await Task.sleep(for: .milliseconds(10)) }
        }.value
    }

    static func recover(stateDirectory: URL, binary: URL) async throws {
        let url = stateDirectory.appendingPathComponent("mulee-process.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let identity: Ed2kProcessIdentity
        do {
            identity = try JSONDecoder().decode(Ed2kProcessIdentity.self, from: Data(contentsOf: url))
        } catch {
            throw EngineError.launchFailed("电驴进程记录损坏，无法安全核验旧进程")
        }
        if identity.matches(binary: binary) {
            // 调用方已持有状态目录的 flock；其他活跃引擎不能进入恢复过程。
            kill(identity.pid, SIGTERM)
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while identity.matches(binary: binary) && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            if identity.matches(binary: binary) { kill(identity.pid, SIGKILL) }
            let forcedDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            while identity.matches(binary: binary) && ContinuousClock.now < forcedDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            guard !identity.matches(binary: binary) else { throw EngineError.launchFailed("旧电驴进程无法退出") }
        }
        try FileManager.default.removeItem(at: url)
    }
}
