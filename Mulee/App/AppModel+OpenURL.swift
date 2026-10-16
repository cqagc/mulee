import Foundation
import MuleeCore

extension AppModel {
    /// 在确认草稿后，将来源与临时密码绑定到本次新建的任务。
    func addTasks(
        from links: [ParsedLink], autoExtract: Bool, directory: URL? = nil,
        filePriorities: [ParsedLink: [Int]] = [:],
        torrentDownloadModes: [ParsedLink: (sequentialDownload: Bool, firstLastPriority: Bool)] = [:],
        videoEntries: [ParsedLink: YtDlpPlaylistEntry] = [:],
        contexts: [ParsedLink: NewTaskContext]
    ) {
        if let coordinator {
            Task {
                for link in links.reversed() {
                    let previousIDs = Set(tasks.map(\.id))
                    await coordinator.add(
                        links: [link], autoExtract: autoExtract, directory: directory,
                        filePriorities: filePriorities, torrentDownloadModes: torrentDownloadModes, videoEntries: videoEntries,
                        requestContexts: contexts.mapValues(\.requestContext), checksums: contexts.compactMapValues(\.checksum)
                    )
                    for index in tasks.indices where !previousIDs.contains(tasks[index].id) && tasks[index].sourceLink == link.original {
                        tasks[index].sourcePageURL = contexts[link]?.sourcePageURL
                        if let password = contexts[link]?.password { pagePasswords[tasks[index].id] = password }
                    }
                }
            }
            return
        }
        let newTasks = links.map { link in
            var task = DownloadTask(link: link, autoExtract: autoExtract)
            if let entry = videoEntries[link] { task.name = "P\(entry.index) \(entry.title)" }
            task.sourcePageURL = contexts[link]?.sourcePageURL
            task.requestContext = contexts[link]?.requestContext.withoutCookie
            task.checksum = contexts[link]?.checksum
            if link.kind == .http, let name = contexts[link]?.requestContext.suggestedFilename {
                task.name = name
                task.fileExtension = URL(fileURLWithPath: name).pathExtension
            }
            if let password = contexts[link]?.password { pagePasswords[task.id] = password }
            return task
        }
        tasks.insert(contentsOf: newTasks, at: 0)
        selectedTaskID = newTasks.first?.id ?? selectedTaskID
    }
}
