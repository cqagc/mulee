import Foundation

/// HTTP / HTTPS / FTP 下载引擎：以子进程运行 aria2c，通过本机 JSON-RPC 控制。
///
/// 占位实现，由 aria2 工人替换。初始化签名是 App 层依赖的契约，不要改。
public actor Aria2Engine: DownloadEngine {
    public nonisolated let kind: TaskKind = .http

    private let stateDirectory: URL
    private let binaryURL: URL?

    /// - Parameters:
    ///   - stateDirectory: 存放 aria2 配置、会话、日志的目录（App 传 Application Support/Mulee/aria2）。
    ///   - binaryURL: 指定 aria2c 路径；nil 时按 App 包内 Helpers、环境变量 MULEE_ARIA2C、Homebrew 路径依次查找。
    public init(stateDirectory: URL, binaryURL: URL? = nil) {
        self.stateDirectory = stateDirectory
        self.binaryURL = binaryURL
    }

    public func start(options: EngineOptions) async throws { throw EngineError.binaryNotFound }
    public func stop() async {}
    public func apply(options: EngineOptions) async throws { throw EngineError.notRunning }
    public func add(link: ParsedLink, directory: URL?) async throws -> String { throw EngineError.notRunning }
    public func pause(_ engineTaskID: String) async throws { throw EngineError.notRunning }
    public func resume(_ engineTaskID: String) async throws { throw EngineError.notRunning }
    public func remove(_ engineTaskID: String, deleteFiles: Bool) async throws { throw EngineError.notRunning }
    public func snapshots() async throws -> [EngineTaskSnapshot] { throw EngineError.notRunning }
}
