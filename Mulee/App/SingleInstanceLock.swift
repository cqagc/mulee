import Darwin
import Foundation

/// 锁文件永不删除，避免旧 inode 仍被锁住时另一个进程锁到新文件。
final class SingleInstanceLock {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire(in directory: URL) throws -> SingleInstanceLock? {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let descriptor = open(directory.appending(path: "instance.lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        let owner = Array("\(getpid())\n".utf8)
        guard fchmod(descriptor, 0o600) == 0,
              ftruncate(descriptor, 0) == 0,
              owner.withUnsafeBytes({ write(descriptor, $0.baseAddress, $0.count) }) == owner.count else {
            let code = errno
            close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return SingleInstanceLock(descriptor: descriptor)
    }

    static func ownerProcessID(in directory: URL) throws -> pid_t? {
        let descriptor = open(directory.appending(path: "instance.lock").path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        var bytes = [UInt8](repeating: 0, count: 32)
        let count = read(descriptor, &bytes, bytes.count)
        guard count > 0 else { return nil }
        return pid_t(String(decoding: bytes.prefix(count), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    deinit {
        close(descriptor)
    }
}
