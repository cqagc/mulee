import Darwin
import Foundation

/// 防止同一状态目录同时启动两个引擎；App 崩溃后内核自动释放锁。
struct Ed2kStateLock: Sendable {
    let descriptor: Int32

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        descriptor = open(directory.appendingPathComponent("mulee.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw EngineError.launchFailed("无法锁定电驴状态目录") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw EngineError.launchFailed("该电驴状态目录已被另一个引擎使用")
        }
    }

    func unlock() { close(descriptor) }
}
