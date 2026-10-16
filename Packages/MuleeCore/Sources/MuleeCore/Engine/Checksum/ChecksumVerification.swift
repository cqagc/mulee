import Foundation

public struct ChecksumVerification: Sendable, Hashable, Codable {
    public let expected: DownloadChecksum
    public let actual: String?
    public let errorMessage: String?

    public var matches: Bool? { actual.map { $0 == expected.digest } }

    public init(expected: DownloadChecksum, actual: String? = nil, errorMessage: String? = nil) {
        self.expected = expected
        self.actual = actual
        self.errorMessage = errorMessage
    }
}
