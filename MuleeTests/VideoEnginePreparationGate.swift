import Foundation

/// 让工具准备在测试指定的位置继续，不依赖真实网络或定时延迟。
@MainActor
final class VideoEnginePreparationGate {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        let pair = AsyncStream<Void>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func wait() async {
        for await _ in stream { return }
    }

    func release() {
        continuation.yield(())
        continuation.finish()
    }
}
