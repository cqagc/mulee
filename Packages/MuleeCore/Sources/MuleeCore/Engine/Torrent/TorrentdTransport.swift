import Foundation

/// 一次进程会话的字节传输；输出流结束表示进程退出。每次重启使用新实例。
protocol TorrentdTransport: Sendable {
    func start() async throws -> AsyncStream<Data>
    func send(_ data: Data) async throws
    func isRunning() async -> Bool
    func finish(grace: Duration, terminationGrace: Duration) async
}
