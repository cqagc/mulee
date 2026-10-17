import Foundation

struct YtDlpFileSafety: Sendable {
    static func belongs(_ url: URL, to job: YtDlpJob) -> Bool {
        let root = job.directory.standardizedFileURL.resolvingSymlinksInPath()
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        return resolved.deletingLastPathComponent().pathComponents == root.pathComponents
            && url.lastPathComponent.hasPrefix(job.id + "-")
    }

    static func removeEmbeddedSubtitles(
        for job: YtDlpJob, video: URL, languages: [String], mode: YtDlpOutputOptions.SubtitleMode
    ) throws {
        guard mode == .embed, job.site != .bilibili, job.outputOptions?.audioOnly != true,
              belongs(video, to: job) else { return }
        let stem = video.deletingPathExtension().lastPathComponent
        let names = Set(languages.filter(YtDlpSubtitleLanguage.isValidID).flatMap { language in
            ["vtt", "srt", "ass"].map { stem + "." + language + "." + $0 }
        })
        let files = try FileManager.default.contentsOfDirectory(
            at: job.directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        for file in files where names.contains(file.lastPathComponent) && belongs(file, to: job) {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            try FileManager.default.removeItem(at: file)
        }
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
