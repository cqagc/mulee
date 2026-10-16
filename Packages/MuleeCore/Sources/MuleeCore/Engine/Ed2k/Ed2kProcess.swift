import Darwin
import Foundation
import OSLog

/// 长期状态由 Ed2kEngine actor 持有；Process 自身提供线程安全的 isRunning。
struct Ed2kProcess: Sendable {
    private let process: Process
    let identity: Ed2kProcessIdentity
    static let logger = Logger(subsystem: "MuleeCore", category: "Ed2k")

    init(binary: URL, stateDirectory: URL, parentProcessID: pid_t = getpid()) throws {
        let child = Process()
        let handshake = Pipe()
        child.executableURL = URL(filePath: "/bin/bash")
        child.arguments = ["-c", Self.supervisor, "mulee-amuled", String(parentProcessID), binary.path,
                           "--config-dir", stateDirectory.path, "--log-stdout"]
        var environment = ProcessInfo.processInfo.environment
        environment["LANG"] = "en_US.UTF-8"
        environment["LC_ALL"] = "en_US.UTF-8"
        environment["HOME"] = stateDirectory.path
        child.environment = environment
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = handshake
        child.standardError = FileHandle.nullDevice
        try child.run()
        try handshake.fileHandleForWriting.close()
        let data = handshake.fileHandleForReading.availableData
        try handshake.fileHandleForReading.close()
        let pid = Int32(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        var observedIdentity: Ed2kProcessIdentity?
        // 握手返回的是 amuled PID，恢复记录不能误存监督 shell 的身份。
        if let pid {
            for _ in 0..<100 {
                observedIdentity = Ed2kProcessIdentity.read(pid)
                if observedIdentity?.executable == binary.resolvingSymlinksInPath().path { break }
                if !child.isRunning { break }
                usleep(1_000)
            }
        }
        guard let identity = observedIdentity else {
            if child.isRunning { child.terminate() }
            throw EngineError.launchFailed(String(localized: "无法核验电驴子进程身份", bundle: .module))
        }
        process = child
        self.identity = identity
    }

    var isRunning: Bool { process.isRunning }

    func finish(waitForExit: Duration = .zero) async {
        // 即使 stop 的调用方取消，也要完成退出和回收。
        await Task.detached { [process, identity] in
            let gracefulDeadline = ContinuousClock.now.advanced(by: waitForExit)
            while process.isRunning && ContinuousClock.now < gracefulDeadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            if process.isRunning { process.terminate() }
            let deadline = ContinuousClock.now.advanced(by: .seconds(12))
            while process.isRunning && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(25))
            }
            if process.isRunning {
                if Ed2kProcessIdentity.read(identity.pid) == identity { kill(-identity.pid, SIGKILL) }
                kill(process.processIdentifier, SIGKILL)
            }
            while process.isRunning { try? await Task.sleep(for: .milliseconds(10)) }
        }.value
    }

    // 参数始终经位置参数传递，路径不参与 shell 源码插值。
    private static let supervisor = #"""
    exec 2>/dev/null
    set -m
    parent="$1"
    shift
    "$@" >/dev/null 2>&1 &
    child=$!
    printf '%s\n' "$child"
    exec 1>/dev/null
    supervisor=$$
    watcher=""
    stop_watcher() {
        [ -n "$watcher" ] || return
        kill -TERM -- "-$watcher" 2>/dev/null || true
        kill -KILL -- "-$watcher" 2>/dev/null || true
        wait "$watcher" 2>/dev/null
    }
    cleanup() {
        trap '' TERM INT HUP
        # aMule 的 SIGTERM 走 OnCoreTimer -> OnExit，保存 part 文件后退出。
        kill -TERM -- "-$child" 2>/dev/null || true
        for ((attempt=0; attempt<100; attempt++)); do
            kill -0 "$child" 2>/dev/null || break
            /bin/sleep 0.1
        done
        kill -KILL -- "-$child" 2>/dev/null || true
        wait "$child" 2>/dev/null
        stop_watcher
    }
    trap 'cleanup; exit 143' TERM INT HUP
    (
        while kill -0 "$parent" 2>/dev/null; do /bin/sleep 0.25; done
        kill -TERM "$supervisor" 2>/dev/null
    ) &
    watcher=$!
    wait "$child"
    result=$?
    kill -TERM -- "-$child" 2>/dev/null || true
    kill -KILL -- "-$child" 2>/dev/null || true
    stop_watcher
    exit "$result"
    """#

    static func recover(stateDirectory: URL, binary: URL) async throws {
        let url = stateDirectory.appendingPathComponent("mulee-process.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let identity: Ed2kProcessIdentity
        do {
            identity = try JSONDecoder().decode(Ed2kProcessIdentity.self, from: Data(contentsOf: url))
        } catch {
            throw EngineError.launchFailed(String(localized: "电驴进程记录损坏，无法安全核验旧进程", bundle: .module))
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
            guard !identity.matches(binary: binary) else { throw EngineError.launchFailed(String(localized: "旧电驴进程无法退出", bundle: .module)) }
        }
        try FileManager.default.removeItem(at: url)
    }
}
