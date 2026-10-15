import Darwin
import Foundation

/// Process 和写管道由 actor 独占；读管道只在回调中读取并向流传值。
actor TorrentdProcessTransport: TorrentdTransport {
    private let binary: URL
    private let stateDirectory: URL
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?

    init(binary: URL, stateDirectory: URL) {
        self.binary = binary
        self.stateDirectory = stateDirectory
    }

    func start() throws -> AsyncStream<Data> {
        guard process == nil else { throw EngineError.launchFailed("BT 引擎已启动") }
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        // 避免子进程恰好退出时，写入关闭的管道向 App 发送 SIGPIPE。
        guard fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw EngineError.launchFailed("无法创建 BT 引擎通信管道")
        }
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
            } else {
                continuation.yield(data)
            }
        }
        process.executableURL = binary
        process.arguments = ["--state-dir", stateDirectory.path]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            continuation.finish()
            throw EngineError.launchFailed("BT 引擎启动失败，请检查辅助程序的执行权限")
        }
        self.process = process
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        return stream
    }

    func send(_ data: Data) throws {
        guard let process, process.isRunning, let input else { throw EngineError.notRunning }
        do {
            try input.write(contentsOf: data)
        } catch {
            throw EngineError.notRunning
        }
    }

    func isRunning() -> Bool { process?.isRunning == true }

    func finish(grace: Duration, terminationGrace: Duration) async {
        // 清理使用独立任务，调用方取消也必须完成回收。
        let cleanup = Task.detached { [process, input] in
            try? input?.close()
            guard let process else { return }
            let deadline = ContinuousClock.now.advanced(by: grace)
            while process.isRunning && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(25))
            }
            if process.isRunning { process.terminate() }
            let terminationDeadline = ContinuousClock.now.advanced(by: terminationGrace)
            while process.isRunning && ContinuousClock.now < terminationDeadline {
                try? await Task.sleep(for: .milliseconds(25))
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            while process.isRunning { try? await Task.sleep(for: .milliseconds(10)) }
        }
        await cleanup.value
        output?.readabilityHandler = nil
        try? output?.close()
        input = nil
        output = nil
        process = nil
    }
}
