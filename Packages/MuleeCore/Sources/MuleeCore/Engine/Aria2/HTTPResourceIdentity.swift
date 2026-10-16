import Foundation

public struct HTTPResourceIdentity: Sendable, Hashable, Codable {
    public let size: Int64?
    public let etag: String?
    public let contentType: String?

    public init(size: Int64?, etag: String? = nil, contentType: String? = nil) {
        self.size = size
        self.etag = etag
        self.contentType = contentType
    }

    /// 未知大小、缺失原 ETag 都不能作为安全续传的证据。
    public func validateReplacement(_ new: Self) throws {
        guard let size, let newSize = new.size else { throw HTTPDownloadFailure.unknownIdentity }
        guard size == newSize else { throw HTTPDownloadFailure.resourceChanged }
        if let etag {
            guard let newTag = new.etag else { throw HTTPDownloadFailure.unknownIdentity }
            guard etag == newTag else { throw HTTPDownloadFailure.resourceChanged }
        }
        if contentType != "text/html", new.contentType == "text/html" {
            throw HTTPDownloadFailure.webPage
        }
    }
}
