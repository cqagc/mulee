import Foundation
import MuleeCore

/// 编码检测、密码尝试、嵌套解压和成功后的原包处理全部复用核心实现。
actor ArchiveExtractionService: ArchiveExtracting {
    private let extractor: ArchiveExtractor

    init(binary: URL? = nil, passwords: any PasswordProviding = KeychainPasswordProvider()) {
        extractor = ArchiveExtractor(binary: binary, passwords: passwords)
    }

    func extract(
        archive: URL,
        destination: URL,
        rules: [UnzipRule],
        sourceURL: URL?,
        options: ExtractionOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async -> ExtractionOutcome {
        ExtractionOutcome(await extractor.extract(
            archive: archive, destination: destination, rules: rules,
            sourceURL: sourceURL, options: options, progress: progress
        ))
    }
}
