import Darwin
import Foundation

/// 每次调用独占 Process 和管道，在同一个任务中轮询非阻塞输出，无共享可变状态。
enum SevenZipProcess {
    static var homebrewBinary: URL? {
        ["/opt/homebrew/bin/7zz", "/usr/local/bin/7zz"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }.map { URL(fileURLWithPath: $0) }
    }

    @concurrent
    static func run(
        binary: URL,
        arguments: [String],
        password: String? = nil,
        directory: URL? = nil,
        timeout: Duration = .seconds(600),
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> SevenZipOutput {
        try Task.checkCancellation()
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw ExtractionFailure.executableMissing }
        let input = (password ?? "") + "\n"
        guard !((password ?? "").contains("\n")), !((password ?? "").contains("\r")),
              input.utf8.count <= 4096 else { throw ExtractionFailure.invalidPassword }
        let process = Process()
        let output = Pipe()
        let stdin = Pipe()
        process.executableURL = binary
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["LANG"] = "en_US.UTF-8"
        environment["LC_ALL"] = "en_US.UTF-8"
        process.environment = environment
        let (exitStream, exitContinuation) = AsyncStream<Int32>.makeStream(bufferingPolicy: .bufferingNewest(1))
        process.terminationHandler = { finished in
            exitContinuation.yield(finished.terminationStatus)
            exitContinuation.finish()
        }
        process.standardInput = stdin
        process.standardOutput = output
        process.standardError = output
        // 7zz 26.04 实测：不传 -p 时从 stdin 读取密码，包括加密文件头。
        // 预先写入短密码再启动，避免无密码压缩包退出后写管道触发 SIGPIPE。
        try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let descriptor = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else { throw POSIXError(.EIO) }
        defer {
            output.fileHandleForReading.closeFile()
            output.fileHandleForWriting.closeFile()
            stdin.fileHandleForReading.closeFile()
        }
        try process.run()
        // 独立任务只负责等待系统的终止回调，不继承调用者的取消状态。
        // 清理阶段 await value 必须等到进程回收；不能在协作线程池同步 waitUntilExit。
        let exit = Task { @concurrent in
            for await status in exitStream { return status }
            return Int32(-1)
        }
        output.fileHandleForWriting.closeFile()
        do {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 16_384)
            var progressTail = ""
            while true {
                try Task.checkCancellation()
                guard clock.now < deadline else { throw ExtractionFailure.timedOut }
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count > 0 {
                    data.append(contentsOf: buffer.prefix(count))
                    guard data.count <= 64 * 1024 * 1024 else { throw ExtractionFailure.damagedArchive }
                    progressTail += String(decoding: buffer.prefix(count), as: UTF8.self)
                    if let progress {
                        for percentage in percentages(in: progressTail) { progress(percentage) }
                    }
                    progressTail = String(progressTail.suffix(8))
                } else if count == 0 {
                    break
                } else if errno != EAGAIN && errno != EINTR {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                } else {
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
            let status = await exit.value
            try Task.checkCancellation()
            return SevenZipOutput(status: status, text: String(decoding: data, as: UTF8.self))
        } catch {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            _ = await exit.value
            throw error
        }
    }

    static func percentages(in output: String) -> [Double] {
        guard let regex = try? NSRegularExpression(pattern: "(?:^|[^0-9])([0-9]{1,3})%") else { return [] }
        return regex.matches(in: output, range: NSRange(output.startIndex..., in: output)).compactMap {
            guard let range = Range($0.range(at: 1), in: output), let value = Double(output[range]), value <= 100 else { return nil }
            return value / 100
        }
    }

}
