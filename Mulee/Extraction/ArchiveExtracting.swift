import Foundation
import MuleeCore

/// App 的解压入口；测试可注入内存实现，不启动外部进程。
nonisolated protocol ArchiveExtracting: Sendable {
    func extract(
        archive: URL,
        destination: URL,
        rules: [UnzipRule],
        sourceURL: URL?,
        options: ExtractionOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async -> ExtractionOutcome
}
