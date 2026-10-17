import Foundation
import MuleeCore

extension AppModel {
    static func isPureVideoPlaylist(_ link: ParsedLink) -> Bool {
        link.playlistID != nil && link.youtubeVideoID == nil
    }

    static func singleVideoDownloadLink(_ link: ParsedLink) -> ParsedLink {
        guard case .video(_, .youtube, _) = link, link.playlistID != nil,
              let url = link.singleVideoURL else { return link }
        return .video(url: url, site: .youtube, original: url.absoluteString)
    }

    /// 面板以外的入口也必须先选集，不能把整个列表交给引擎。
    func redirectVideoPlaylists(
        in links: [ParsedLink], directory: URL?, contexts: [ParsedLink: NewTaskContext] = [:],
        canPresentNewTask: Bool
    ) -> String? {
        let playlists = links.filter(Self.isPureVideoPlaylist)
        guard !playlists.isEmpty else { return nil }
        guard canPresentNewTask else {
            let message = String(localized: "播放列表需要在新建面板里选择要下载的集")
            openURLIssue = message
            return message
        }
        if let directory = playlists.compactMap({ contexts[$0]?.saveDirectory }).first ?? directory {
            pendingNewTaskDirectory = directory
        }
        for link in playlists {
            if let context = contexts[link] { pendingNewTaskContexts[link] = context }
        }
        showNewTask(prefill: playlists.map(\.original).joined(separator: "\n"))
        return nil
    }

    func waitForBrowserHTTPReplacement(_ id: UUID, now: Date = .now) {
        guard let task = tasks.first(where: { $0.id == id && $0.deletedAt == nil && $0.kind == .http }) else { return }
        pendingBrowserHTTPReplacement = nil
        waitingHTTPReplacement = HTTPReplacementWait(
            taskID: id, host: URL(string: task.sourceLink)?.host?.lowercased(),
            filename: task.requestContext?.suggestedFilename ?? task.name, expiresAt: now.addingTimeInterval(300)
        )
    }

    func acceptBrowserHTTPReplacement(_ link: ParsedLink, context: DownloadRequestContext, now: Date = .now) -> Bool {
        guard let waiting = waitingHTTPReplacement else { return false }
        guard now < waiting.expiresAt,
              tasks.contains(where: { $0.id == waiting.taskID && $0.deletedAt == nil }) else {
            waitingHTTPReplacement = nil
            return false
        }
        guard case .http(let url, _, _) = link else { return false }
        let filename = context.suggestedFilename ?? url.lastPathComponent
        guard url.host?.lowercased() == waiting.host || (!filename.isEmpty && filename == waiting.filename) else { return false }
        waitingHTTPReplacement = nil
        pendingBrowserHTTPReplacement = BrowserHTTPReplacement(taskID: waiting.taskID, url: url, context: context)
        selectedTaskID = waiting.taskID
        mainWindowRequest += 1
        return true
    }

    /// 在确认草稿后，将来源与临时密码绑定到本次新建的任务。
    @discardableResult
    func addTasks(
        from links: [ParsedLink], autoExtract: Bool, directory: URL? = nil,
        filePriorities: [ParsedLink: [Int]] = [:],
        torrentDownloadModes: [ParsedLink: (sequentialDownload: Bool, firstLastPriority: Bool)] = [:],
        videoEntries: [ParsedLink: YtDlpPlaylistEntry] = [:],
        contexts: [ParsedLink: NewTaskContext], canPresentNewTask: Bool = true
    ) -> String? {
        if let error = redirectVideoPlaylists(in: links, directory: directory, contexts: contexts, canPresentNewTask: canPresentNewTask) {
            return error
        }
        let acceptedLinks = links.filter { !Self.isPureVideoPlaylist($0) }
        if let coordinator {
            Task {
                for link in acceptedLinks.reversed() {
                    let previousIDs = Set(tasks.map(\.id))
                    let source = Self.singleVideoDownloadLink(link).original
                    await coordinator.add(
                        links: [link], autoExtract: autoExtract, directory: contexts[link]?.saveDirectory ?? directory,
                        filePriorities: filePriorities, torrentDownloadModes: torrentDownloadModes, videoEntries: videoEntries,
                        requestContexts: contexts.mapValues(\.requestContext), checksums: contexts.compactMapValues(\.checksum),
                        videoFormatIDs: contexts.compactMapValues(\.videoFormatID),
                        videoOnlyFormats: contexts.mapValues(\.videoFormatVideoOnly),
                        videoOptions: contexts.compactMapValues(\.videoOptions),
                        videoIdentities: contexts.compactMapValues(\.videoIdentity)
                    )
                    for index in tasks.indices where !previousIDs.contains(tasks[index].id) && tasks[index].sourceLink == source {
                        tasks[index].sourcePageURL = contexts[link]?.sourcePageURL
                        if let password = contexts[link]?.password { pagePasswords[tasks[index].id] = password }
                    }
                    let succeeded = tasks.contains {
                        !previousIDs.contains($0.id) && $0.sourceLink == source
                            && $0.engineTaskID != nil && $0.status != .failed
                    }
                    do {
                        try OpenURLRouter.trashAddedTorrent(
                            link, fromFinder: contexts[link]?.finderTorrent == true,
                            enabled: downloadSettings?.trashTorrentAfterAdd ?? false, succeeded: succeeded
                        )
                    } catch {
                        openURLIssue = String(localized: "任务已添加，但原种子未能移到废纸篓。请检查文件访问权限。")
                    }
                }
            }
            return nil
        }
        let newTasks = acceptedLinks.map { link in
            var task = DownloadTask(link: Self.singleVideoDownloadLink(link), autoExtract: autoExtract)
            if let entry = videoEntries[link] {
                task.name = entry.site == .youtube ? entry.taskTitle : "P\(entry.index) \(entry.title)"
            }
            task.sourcePageURL = contexts[link]?.sourcePageURL
            task.videoIdentity = contexts[link]?.videoIdentity
            task.videoOptions = contexts[link]?.videoOptions
            if let directory = contexts[link]?.saveDirectory ?? directory { task.writeDirectories = [directory] }
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
        return nil
    }
}
