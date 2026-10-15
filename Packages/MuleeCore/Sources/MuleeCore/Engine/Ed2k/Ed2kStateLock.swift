import Darwin
import Foundation

/// 防止同一状态目录同时启动两个引擎；App 崩溃后内核自动释放锁。
struct Ed2kStateLock: Sendable {
    let descriptor: Int32

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        descriptor = open(directory.appendingPathComponent("mulee.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw EngineError.launchFailed(String(localized: "无法锁定电驴状态目录", bundle: .module)) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw EngineError.launchFailed(String(localized: "该电驴状态目录已被另一个引擎使用", bundle: .module))
        }
    }

    func unlock() {
        // close 只释放当前描述符；并发启动的子进程可能暂时继承同一把锁。
        // 显式解锁后，重新启动引擎无需等继承的描述符被 exec/close。
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
