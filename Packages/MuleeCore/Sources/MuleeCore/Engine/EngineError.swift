/// 下载引擎的错误。
public enum EngineError: Error, Sendable, Equatable {
    /// 找不到引擎可执行文件。
    case binaryNotFound
    /// 引擎进程启动失败或启动后没有在规定时间内就绪。
    case launchFailed(String)
    /// 引擎没有在运行（还没 start 或已经退出）。
    case notRunning
    /// 引擎返回了错误（aria2 JSON-RPC 的 error.code / error.message）。
    case rpc(code: Int, message: String)
    /// 引擎返回的数据无法解析。
    case invalidResponse(String)
    /// 引擎不支持这种链接。
    case unsupportedLink
}
