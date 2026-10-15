import Foundation

public struct ExtractionOptions: Sendable {
    public var readArchiveComment: Bool
    public var pagePasswords: [String]
    public var encoding: ArchiveFilenameEncoding
    public var postAction: ExtractionPostAction
    public var recursivelyExtract: Bool
    public var expectedVolumeNames: [String]?
    public var expectedVolumeCount: Int?
    public var timeout: Duration

    public init(
        readArchiveComment: Bool = false,
        pagePasswords: [String] = [],
        encoding: ArchiveFilenameEncoding = .automatic,
        postAction: ExtractionPostAction = .trash,
        recursivelyExtract: Bool = false,
        expectedVolumeNames: [String]? = nil,
        expectedVolumeCount: Int? = nil,
        timeout: Duration = .seconds(600)
    ) {
        self.readArchiveComment = readArchiveComment
        self.pagePasswords = pagePasswords
        self.encoding = encoding
        self.postAction = postAction
        self.recursivelyExtract = recursivelyExtract
        self.expectedVolumeNames = expectedVolumeNames
        self.expectedVolumeCount = expectedVolumeCount
        self.timeout = timeout
    }
}
