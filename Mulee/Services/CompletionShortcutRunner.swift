import Darwin
import Foundation
import MuleeCore

@MainActor
protocol ShortcutProcessRunning {
    func run(arguments: [String], timeout: Duration?) async throws -> String
}

@MainActor
final class SystemShortcutProcessRunner: ShortcutProcessRunning {
    nonisolated enum Failure: LocalizedError {
        case timeout
        case exit(Int32, String)

        var errorDescription: String? {
            switch self {
            case .timeout: String(localized: "读取快捷指令超过 5 秒，请稍后重试。")
            case .exit(let code, let message): message.isEmpty ? String(localized: "快捷指令退出，错误码 \(code)。") : message
            }
        }
    }

    func run(arguments: [String], timeout: Duration?) async throws -> String {
        try await Self.execute(arguments: arguments, timeout: timeout)
    }

    @concurrent nonisolated private static func execute(arguments: [String], timeout: Duration?) async throws -> String {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/shortcuts")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let (events, continuation) = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { continuation.yield($0.terminationStatus); continuation.finish() }
        for pipe in [output, errors] {
            let descriptor = pipe.fileHandleForReading.fileDescriptor
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else { throw POSIXError(.EIO) }
        }
        defer {
            for pipe in [output, errors] {
                pipe.fileHandleForReading.closeFile()
                pipe.fileHandleForWriting.closeFile()
            }
        }
        try process.run()
        output.fileHandleForWriting.closeFile()
        errors.fileHandleForWriting.closeFile()
        let exit = Task { @concurrent in
            for await status in events { return status }
            return Int32(-1)
        }
        let clock = ContinuousClock()
        let deadline = timeout.map { clock.now.advanced(by: $0) }
        var data = Data()
        var errorData = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        do {
            // 两个管道都以非阻塞方式排空；超时或取消不能被未关闭的输出拖住。
            while true {
                try Task.checkCancellation()
                if let deadline, clock.now >= deadline { throw Failure.timeout }
                var received = false
                for (index, pipe) in [output, errors].enumerated() {
                    let count = Darwin.read(pipe.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
                    if count > 0 {
                        received = true
                        if index == 0 { data.append(contentsOf: buffer.prefix(min(count, max(0, 4 * 1024 * 1024 - data.count)))) }
                        else { errorData.append(contentsOf: buffer.prefix(min(count, max(0, 4096 - errorData.count)))) }
                    } else if count < 0, errno != EAGAIN, errno != EINTR {
                        throw POSIXError(.init(rawValue: errno) ?? .EIO)
                    }
                }
                if !process.isRunning, !received { break }
                if !received { try await Task.sleep(for: .milliseconds(10)) }
            }
            let status = await exit.value
            try Task.checkCancellation()
            guard status == 0 else {
                throw Failure.exit(status, String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return String(decoding: data, as: UTF8.self)
        } catch {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            _ = await exit.value
            throw error
        }
    }
}

/// 完成事件按到达顺序串行执行；不把用户选择的名字交给 shell。
@MainActor
final class CompletionShortcutRunner {
    private let settings: SettingsModel
    private let runner: any ShortcutProcessRunning
    private let notify: (String, String) -> Void
    private var seen: Set<UUID>
    private var pending: [(name: String, path: URL)] = []
    private var worker: Task<Void, Never>?
    private var stopped = false

    init(
        settings: SettingsModel, completedIDs: Set<UUID> = [],
        runner: any ShortcutProcessRunning = SystemShortcutProcessRunner(),
        notify: @escaping (String, String) -> Void
    ) {
        self.settings = settings
        self.runner = runner
        self.notify = notify
        seen = completedIDs
    }

    static func arguments(name: String, path: URL) -> [String] {
        ["run", name, "--input-path", path.path]
    }

    static func list(using runner: any ShortcutProcessRunning = SystemShortcutProcessRunner()) async throws -> [String] {
        let output = try await runner.run(arguments: ["list"], timeout: .seconds(5))
        return output.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
    }

    func completed(_ task: DownloadTask) {
        guard !stopped, seen.insert(task.id).inserted, let path = task.savePath, !settings.completionShortcut.isEmpty else { return }
        pending.append((settings.completionShortcut, path))
        guard worker == nil else { return }
        worker = Task { [weak self] in await self?.drain() }
    }

    private func drain() async {
        while !pending.isEmpty, !Task.isCancelled {
            let item = pending.removeFirst()
            do {
                _ = try await runner.run(arguments: Self.arguments(name: item.name, path: item.path), timeout: nil)
            } catch is CancellationError {
                break
            } catch {
                notify(String(localized: "完成后的快捷指令未能运行"), String(localized: "「\(item.name)」：\(error.localizedDescription)"))
            }
        }
        worker = nil
    }

    func waitUntilIdle() async { await worker?.value }

    func stop() {
        stopped = true
        pending.removeAll()
        worker?.cancel()
        worker = nil
    }

    isolated deinit { worker?.cancel() }
}
