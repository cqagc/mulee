import Foundation

struct YtDlpFileSafety: Sendable {
    static func belongs(_ url: URL, to job: YtDlpJob) -> Bool {
        let root = job.directory.standardizedFileURL.resolvingSymlinksInPath()
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        return resolved.deletingLastPathComponent().pathComponents == root.pathComponents
            && url.lastPathComponent.hasPrefix(job.id + "-")
    }

    static func trash(_ job: YtDlpJob) throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: job.directory, includingPropertiesForKeys: nil
        )
        for file in files where belongs(file, to: job) {
            try FileManager.default.trashItem(at: file, resultingItemURL: nil)
        }
    }
}
