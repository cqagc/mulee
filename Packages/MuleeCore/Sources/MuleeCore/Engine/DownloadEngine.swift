import Foundation

/// 一个下载引擎（aria2、libtorrent、amuled、yt-dlp 各实现一个）。
///
/// 引擎以独立子进程运行，App 层通过 actor 串行调用；所有方法在引擎未启动时抛 `EngineError.notRunning`。
/// App 每秒调用一次 `snapshots()` 刷新界面。
public protocol DownloadEngine: Actor {
    /// 负责的任务类型。
    nonisolated var kind: TaskKind { get }

    /// 启动引擎子进程并等待就绪；会恢复上次退出时保存的任务。重复调用无副作用。
    func start(options: EngineOptions) async throws
    /// 保存会话并停止引擎子进程。未启动时直接返回。
    func stop() async
    /// 运行中修改全局设置（限速、并发数、保存目录等）。
    func apply(options: EngineOptions) async throws

    /// 添加下载，返回引擎任务标识。`directory` 为 nil 时用全局保存目录。
    func add(link: ParsedLink, directory: URL?) async throws -> String
    /// 添加后保持暂停，由 App 的统一队列放行。
    func addQueued(link: ParsedLink, directory: URL?) async throws -> String
    func pause(_ engineTaskID: String) async throws
    func resume(_ engineTaskID: String) async throws
    /// 删除任务；`deleteFiles` 为 true 时同时删除已下载的文件（含未完成的临时文件）。
    func remove(_ engineTaskID: String, deleteFiles: Bool) async throws

    /// 引擎里所有任务（进行中、排队、暂停、做种、已完成、出错）的当前状态。
    func snapshots() async throws -> [EngineTaskSnapshot]
}

public extension DownloadEngine {
    /// 不支持原子添加暂停任务的引擎，在同一次调用内立即暂停。
    func addQueued(link: ParsedLink, directory: URL?) async throws -> String {
        let id = try await add(link: link, directory: directory)
        try await pause(id)
        return id
    }
}
