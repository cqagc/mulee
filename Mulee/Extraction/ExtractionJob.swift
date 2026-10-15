import Foundation
import MuleeCore

struct ExtractionJob {
    let id = UUID()
    var taskIDs: Set<DownloadTask.ID>
    var archive: URL
    var destination: URL
    var sourceURL: URL?
    var rules: [UnzipRule]
    var options: ExtractionOptions
    var signature: [String]
}
