import Darwin
import Foundation

/// Process 的引用仅由持有它的 actor 操作；管道通过 AsyncStream 传值。
struct YtDlpProcess: Sendable {
    private let process: Process
    private let pipe: Pipe
    let output: AsyncStream<Data>

    init(binary: URL, arguments: [String], parentProcessID: pid_t = getpid(), cleanupURL: URL? = nil) throws {
        let process = Process()
        let pipe = Pipe()
        self.process = process
        self.pipe = pipe
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        output = stream
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
            } else {
                continuation.yield(data)
            }
        }
        // 独立监督 shell 监视 App PID。App 崩溃后仍可终止 yt-dlp 及 ffmpeg。
        // 所有路径和 URL 经位置参数传递，不插值到 shell 代码里。
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", Self.supervisor, "mulee-ytdlp", String(parentProcessID), cleanupURL?.path ?? "", binary.path] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        process.environment = Self.environment
        do { try process.run() } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            continuation.finish()
            throw error
        }
    }

    var isRunning: Bool { process.isRunning }
    var status: Int32 { process.terminationStatus }

    func finish() async {
        while process.isRunning {
            // Cleanup must also run when its caller was cancelled.
            do { try await Task.sleep(for: .milliseconds(20)) } catch { continue }
        }
    }

    func terminate() async {
        if process.isRunning { process.terminate() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while process.isRunning && ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(20)) } catch { continue }
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        await finish()
    }

    static func capture(binary: URL, arguments: [String]) async throws -> (status: Int32, output: String) {
        let child = try Self(binary: binary, arguments: arguments)
        var data = Data()
        for await chunk in child.output { data.append(chunk) }
        await child.finish()
        return (child.status, String(decoding: data, as: UTF8.self))
    }

    static var environment: [String: String] {
        environment(inheriting: ProcessInfo.processInfo.environment,
                    certificateFileExists: FileManager.default.fileExists(atPath: "/etc/ssl/cert.pem"))
    }

    static func environment(inheriting inherited: [String: String], certificateFileExists: Bool) -> [String: String] {
        var values: [String: String] = [
            "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"
        ]
        // HOME/TMPDIR 为工具正常运行所需，代理保留大小写形式；不继承凭据、配置或 Python 环境。
        for key in ["HOME", "TMPDIR", "http_proxy", "https_proxy", "all_proxy", "no_proxy",
                    "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "SSL_CERT_FILE"] {
            values[key] = inherited[key]
        }
        // 静态 ffmpeg 的 HTTPS 下载需要显式根证书路径；调用方指定的证书必须保留。
        if values["SSL_CERT_FILE"] == nil, certificateFileExists {
            values["SSL_CERT_FILE"] = "/etc/ssl/cert.pem"
        }
        return values
    }

    private static let supervisor = #"""
    exec 3>&2
    exec 2>/dev/null
    set -m
    parent="$1"
    cookie_file="$2"
    shift 2
    "$@" 2>&3 3>&- &
    child=$!
    supervisor=$$
    (
        while kill -0 "$parent" 2>/dev/null; do /bin/sleep 0.25; done
        kill -TERM "$supervisor" 2>/dev/null
    ) 3>&- &
    watcher=$!
    stop_group() {
        kill -TERM -- "-$1" 2>/dev/null || true
        kill -KILL -- "-$1" 2>/dev/null || true
    }
    cleanup_cookie() {
        if [ -n "$cookie_file" ]; then /bin/rm -- "$cookie_file" 2>/dev/null || true; fi
    }
    cleanup() {
        # Job control gives the tool its own process group and restores SIGINT.
        # SIGINT lets yt-dlp flush buffered .part data before forced termination.
        kill -INT -- "-$child" 2>/dev/null || true
        for attempt in 1 2 3 4 5 6 7 8 9 10; do
            kill -0 "$child" 2>/dev/null || break
            /bin/sleep 0.1
        done
        stop_group "$child"
        stop_group "$watcher"
        wait "$child" 2>/dev/null
        wait "$watcher" 2>/dev/null
        cleanup_cookie
    }
    trap 'cleanup; exit 143' TERM INT HUP
    wait "$child"
    result=$?
    stop_group "$child"
    stop_group "$watcher"
    wait "$watcher" 2>/dev/null
    cleanup_cookie
    exit "$result"
    """#
}
