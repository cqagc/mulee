import Foundation

public struct ExtractionResult: Sendable {
    public let status: ExtractionStatus
    public let failure: ExtractionFailure?
    public let matchedRule: UnzipRule?
    public let passwordSource: UnzipPasswordSource?
    public let encoding: ArchiveFilenameEncoding
    public let topLevelItems: [URL]
    public let originalVolumes: [URL]
    public let warnings: [String]
    public let nestedResults: [ExtractionResult]
}
