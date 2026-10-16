import Foundation
import MuleeCore

nonisolated struct ExtractionJob: Sendable {
    let id = UUID()
    var taskIDs: Set<DownloadTask.ID>
    var archive: URL
    var destination: URL
    var sourceURL: URL?
    var rules: [UnzipRule]
    var options: ExtractionOptions
    var signature: [String]
}
