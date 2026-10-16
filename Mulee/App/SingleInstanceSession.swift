import Darwin
import Foundation

/// 早于模型创建，并由静态属性持有到进程退出；关闭窗口不会释放锁。
final class SingleInstanceSession {
    static let current: SingleInstanceSession = {
        do {
            return try SingleInstanceSession(stateDirectory: stateDirectory(isRunningUnitTests: AppEnvironment.isRunningUnitTests))
        } catch {
            // 锁目录不可用时必须停止，不能把 I/O 错误当作允许读写状态的理由。
            FileHandle.standardError.write(Data("Mulee single-instance lock: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }()

    let stateDirectory: URL
    private let lock: SingleInstanceLock?
    var isPrimary: Bool { lock != nil }
    var ownerProcessID: pid_t? { try? SingleInstanceLock.ownerProcessID(in: stateDirectory) }

    init(stateDirectory: URL) throws {
        self.stateDirectory = stateDirectory
        lock = try SingleInstanceLock.acquire(in: stateDirectory)
    }

    static func stateDirectory(isRunningUnitTests: Bool) -> URL {
        if isRunningUnitTests {
            // XCTest 宿主不能争抢用户实例的锁，也不能读取其状态目录。
            return FileManager.default.temporaryDirectory.appending(path: "mulee.tests.instance-\(UUID().uuidString)")
        }
        return URL.applicationSupportDirectory.appending(path: "Mulee", directoryHint: .isDirectory)
    }
}
