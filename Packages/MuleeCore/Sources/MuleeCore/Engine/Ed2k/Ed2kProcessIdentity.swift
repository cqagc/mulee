import Darwin
import Foundation

/// PID、实际可执行路径和内核启动时间共同防止 PID 复用导致误杀。
struct Ed2kProcessIdentity: Codable, Sendable, Equatable {
    let pid: pid_t
    let executable: String
    let startSeconds: UInt64
    let startMicroseconds: UInt64

    static func read(_ pid: pid_t) -> Self? {
        guard pid > 1, pid != getpid() else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_uid == getuid() else { return nil }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &path, UInt32(path.count))
        guard length > 0 else { return nil }
        let bytes = path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let executable = URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self)).resolvingSymlinksInPath().path
        return Self(pid: pid, executable: executable, startSeconds: info.pbi_start_tvsec,
                    startMicroseconds: info.pbi_start_tvusec)
    }

    func matches(binary: URL) -> Bool {
        executable == binary.resolvingSymlinksInPath().path && Self.read(pid) == self
    }
}
