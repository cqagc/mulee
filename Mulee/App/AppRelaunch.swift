import Foundation

/// 辅助进程必须等旧进程退出、单实例锁释放后，再交给 Launch Services。
enum AppRelaunch {
    static func waitingProcess(processID: Int32, command: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = [
            "-c",
            """
            while /bin/kill -0 "$1" 2>/dev/null; do
                /bin/sleep 0.1
            done
            shift
            exec "$@"
            """,
            "mulee-relaunch", String(processID)
        ] + command
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }

    static func launchAfterExit() {
        let process = waitingProcess(
            processID: ProcessInfo.processInfo.processIdentifier,
            command: ["/usr/bin/open", "-n", Bundle.main.bundleURL.path]
        )
        do {
            try process.run()
        } catch {
            // 辅助进程启动失败时保留正常退出；下次手动打开仍使用已保存的语言。
            NSLog("Mulee relaunch helper failed: %@", error.localizedDescription)
        }
    }
}
