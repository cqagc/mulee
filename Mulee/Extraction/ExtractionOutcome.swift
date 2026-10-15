import Foundation
import MuleeCore

/// 核心结果的 App 值类型，便于使用假的解压器验证协调过程。
nonisolated struct ExtractionOutcome: Sendable {
    var status: ExtractionStatus
    var failure: ExtractionFailure?
    var matchedRule: UnzipRule?
    var encoding: ArchiveFilenameEncoding = .utf8
    var items: [URL] = []
    var warnings: [String] = []

    init(
        status: ExtractionStatus,
        failure: ExtractionFailure? = nil,
        matchedRule: UnzipRule? = nil,
        encoding: ArchiveFilenameEncoding = .utf8,
        items: [URL] = [],
        warnings: [String] = []
    ) {
        self.status = status
        self.failure = failure
        self.matchedRule = matchedRule
        self.encoding = encoding
        self.items = items
        self.warnings = warnings
    }

    init(_ result: ExtractionResult) {
        status = result.status
        failure = result.failure
        matchedRule = result.matchedRule
        encoding = result.encoding
        items = result.topLevelItems
        warnings = result.warnings + result.nestedResults.flatMap { child in
            child.warnings + (child.failure.map { ["嵌套压缩包：\($0.localizedDescription)"] } ?? [])
        }
    }
}
