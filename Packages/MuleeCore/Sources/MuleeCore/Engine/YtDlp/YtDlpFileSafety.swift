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
        let finalNames = Set(job.finalFiles ?? [])
        for file in files where belongs(file, to: job) || isFinalFile(file, of: job, names: finalNames) {
            try FileManager.default.trashItem(at: file, resultingItemURL: nil)
        }
    }

    /// 改名后的成品只认任务记录过的文件名，且必须是任务目录里的普通文件。
    private static func isFinalFile(_ url: URL, of job: YtDlpJob, names: Set<String>) -> Bool {
        guard names.contains(url.lastPathComponent) else { return false }
        let root = job.directory.standardizedFileURL.resolvingSymlinksInPath()
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return url.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath().pathComponents == root.pathComponents
            && values?.isRegularFile == true && values?.isSymbolicLink != true
    }
}
