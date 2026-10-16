import Foundation
import MuleeCore
import Observation

/// 新建下载草稿。解析器可注入，面板不负责实现链接识别。
@Observable
final class NewTaskModel {
    var inputText: String {
        didSet { parseInput() }
    }
    private(set) var inputRows: [SmartPasteParser.Row] = []
    var diskWarning: String?
    var diskCheckNote: String?
    var diskConfirmed = false
    var duplicateChoice: DownloadRequestContext.DuplicateAction?
    private(set) var needsDuplicateChoice = false
    private(set) var isChecking = false
    private(set) var links: [NewTaskLinkModel] = []
    var saveDirectory: URL {
        didSet { diskConfirmed = false }
    }
    private var lastCheckedBytes: Int64?
    var autoExtract: Bool
    private var contexts: [ParsedLink: NewTaskContext] = [:]

    private let parser: ((String) -> [ParsedLink])?
    private let metadataProvider: (any TorrentMetadataProvider)?

    init(
        inputText: String = "",
        saveDirectory: URL = URL.homeDirectory.appending(path: "Downloads/Mulee", directoryHint: .isDirectory),
        autoExtract: Bool = true,
        parser: ((String) -> [ParsedLink])? = nil,
        metadataProvider: (any TorrentMetadataProvider)? = nil
    ) {
        self.inputText = inputText
        self.saveDirectory = saveDirectory
        self.autoExtract = autoExtract
        self.parser = parser
        self.metadataProvider = metadataProvider
        parseInput()
    }

    var parsedLinks: [ParsedLink] { links.map(\.link) }
    var linkCount: Int { links.count }
    var canStartDownload: Bool { !links.isEmpty && links.allSatisfy(\.canStart) && !isChecking }
    var filePriorities: [ParsedLink: [Int]] {
        Dictionary(uniqueKeysWithValues: links.compactMap { item in
            item.filePriorities.map { (item.link, $0) }
        })
    }
    var hasVideoLinks: Bool { links.contains { $0.link.kind == .video } }
    var torrentDownloadModes: [ParsedLink: (sequentialDownload: Bool, firstLastPriority: Bool)] {
        Dictionary(uniqueKeysWithValues: links.filter { $0.link.kind == .bittorrent }.map {
            ($0.link, (sequentialDownload: $0.sequentialDownload, firstLastPriority: $0.firstLastPriority))
        })
    }
    var showsAutoExtract: Bool { links.isEmpty || links.contains { $0.link.kind != .video } }

    var videoLoginSites: [VideoSite] {
        let sites = Set(parsedLinks.compactMap { link -> VideoSite? in
            guard case .video(_, let site, _) = link, site != .other else { return nil }
            return site
        })
        return [VideoSite.bilibili, .youtube].filter { sites.contains($0) }
    }

    func videoLoginHintSites(loggedInSites: Set<VideoSite>) -> [VideoSite] {
        videoLoginSites.filter { !loggedInSites.contains($0) }
    }

    var saveDirectoryLabel: String {
        let homePath = URL.homeDirectory.path
        let path = saveDirectory.path
        if path == homePath { return "~" }
        if path.hasPrefix(homePath + "/") {
            return "~" + path.dropFirst(homePath.count)
        }
        return path
    }

    /// 从全局状态取走预填文本，追加到已有草稿；空预填不改变草稿。
    func consumePendingText(from model: AppModel) {
        let pendingText = model.pendingNewTaskText
        guard !pendingText.isEmpty else { return }
        if let directory = model.pendingNewTaskDirectory {
            saveDirectory = directory
            model.pendingNewTaskDirectory = nil
        }
        contexts.merge(model.pendingNewTaskContexts) { _, new in new }
        model.pendingNewTaskContexts = [:]
        mergePrefillText(pendingText)
        model.pendingNewTaskText = ""
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "MuleeOpenURLDiagnostics") {
            FileHandle.standardOutput.write(Data("Mulee OpenURL draft links: \(linkCount)\n".utf8))
        }
        #endif
    }

    func mergePrefillText(_ text: String) {
        guard !text.isEmpty else { return }
        let separator = inputText.isEmpty || inputText.hasSuffix("\n") ? "" : "\n"
        inputText += separator + text
    }

    var downloadLinks: [ParsedLink] {
        links.flatMap { item in
            item.selectedVideoEntries.isEmpty ? [item.link] : item.selectedVideoEntries.map(\.link)
        }
    }

    var videoEntries: [ParsedLink: YtDlpPlaylistEntry] {
        Dictionary(links.flatMap(\.selectedVideoEntries).map { ($0.link, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func createTasks(in model: AppModel) {
        guard canStartDownload else { return }
        model.bitTorrent?.confirmWatchedDrafts(downloadLinks.filter { link in
            !links.contains { $0.duplicateMessage != nil && ($0.link == link || $0.selectedVideoEntries.contains { $0.link == link }) }
        })
        var expandedContexts = contexts
        for item in links {
            var context = contexts[item.link] ?? NewTaskContext()
            context.requestContext = item.requestContext
            context.checksum = item.checksum
            context.videoFormatID = item.selectedVideoFormat?.id
            context.videoFormatVideoOnly = item.selectedVideoFormat?.videoOnly ?? false
            expandedContexts[item.link] = context
            for entry in item.selectedVideoEntries { expandedContexts[entry.link] = context }
        }
        model.addTasks(
            from: downloadLinks.filter { link in
                !links.contains { $0.duplicateMessage != nil && ($0.link == link || $0.selectedVideoEntries.contains { $0.link == link }) }
            }, autoExtract: autoExtract, directory: saveDirectory,
            filePriorities: filePriorities, torrentDownloadModes: torrentDownloadModes,
            videoEntries: videoEntries, contexts: expandedContexts
        )
    }

    var knownDownloadBytes: Int64 {
        links.filter { $0.duplicateMessage == nil }.reduce(Int64(0)) { total, item in
            let size = item.knownDownloadSize ?? 0
            let (sum, overflow) = total.addingReportingOverflow(size)
            return overflow ? Int64.max : sum
        }
    }

    /// 容量读取失败只作说明；已知会越过保护线时必须得到面板内确认。
    func checkDisk(using check: (Int64, URL) throws -> Bool) -> Bool {
        diskCheckNote = nil
        let bytes = knownDownloadBytes
        if lastCheckedBytes != bytes { diskConfirmed = false }
        lastCheckedBytes = bytes
        do {
            if try check(bytes, saveDirectory) {
                diskWarning = String(localized: "这些文件下载后可能越过磁盘保护线。请清理空间、换保存目录，或确认后继续。")
                return diskConfirmed
            }
            diskWarning = nil
        } catch {
            diskWarning = nil
            diskCheckNote = String(localized: "无法读取磁盘剩余空间，仍可添加；请确认保存目录有足够空间。")
        }
        return true
    }

    func checkBeforeAdding(in model: AppModel, settings: SettingsModel) async -> Bool {
        guard canStartDownload else { return false }
        isChecking = true
        defer { isChecking = false }
        let originalText = inputText
        let directory = saveDirectory
        var seenHashes = Set<String>()
        for item in links {
            guard let hash = item.infoHash else { continue }
            let existing = NewTaskLinkModel.existingTorrent(infoHash: hash, tasks: model.tasks)
            let repeated = !seenHashes.insert(hash).inserted
            guard existing != nil || repeated else {
                item.duplicateMessage = nil
                item.duplicateTaskID = nil
                item.canMergeTrackers = false
                item.duplicateAcknowledged = false
                continue
            }
            item.duplicateTaskID = existing?.engineTaskID
            item.canMergeTrackers = false
            if existing?.deletedAt != nil {
                item.duplicateMessage = String(localized: "这个种子已在最近删除里，请恢复任务，或彻底删除后再添加。")
            } else if repeated, existing == nil {
                item.duplicateMessage = String(localized: "本次列表中已有相同种子。请保留第一项，跳过本次重复项。")
            } else if item.torrentInfo?.isPrivate == true {
                item.duplicateMessage = String(localized: "这个私有种子已存在，不会合并 tracker。请使用已有任务。")
            } else if let id = existing?.engineTaskID, let engine = model.bitTorrent?.engine,
                      let info = try? await engine.taskInfo(id), info.hasMetadata {
                if info.isPrivate {
                    item.duplicateMessage = String(localized: "这个私有种子已存在，不会合并 tracker。请使用已有任务。")
                } else {
                    item.canMergeTrackers = !item.trackers.isEmpty
                    item.duplicateMessage = String(localized: "这个公开种子已存在。可合并本次 tracker，或保留已有任务。")
                }
            } else {
                item.duplicateMessage = String(localized: "这个种子已存在，尚无法确认公开状态，不会合并 tracker。请使用已有任务。")
            }
        }
        guard inputText == originalText, saveDirectory == directory, !Task.isCancelled else { return false }
        needsDuplicateChoice = settings.duplicateAction == .ask && links.contains { $0.link.kind == .http }
        let duplicatesReady = links.allSatisfy { $0.duplicateMessage == nil || $0.duplicateAcknowledged }
        let diskReady = checkDisk { size, directory in
            guard size > 0, let protection = model.diskReserveMonitor else { return false }
            return try protection.requiresConfirmation(forKnownBytes: size, in: directory)
        }
        guard duplicatesReady, diskReady, !needsDuplicateChoice || duplicateChoice != nil else { return false }
        let action = settings.duplicateAction == .ask ? (duplicateChoice ?? .rename) : settings.duplicateAction
        var reserved = Set<String>()
        for item in links where item.link.kind == .http {
            item.requestContext.duplicateAction = action
            guard case .http(let url, _, _) = item.link else { continue }
            let name = item.requestContext.suggestedFilename ?? url.lastPathComponent
            guard action == .rename, !name.isEmpty else { continue }
            let available = Self.availableFilename(name, in: saveDirectory, reserved: reserved)
            item.requestContext.suggestedFilename = available
            reserved.insert(available)
        }
        return true
    }

    static func availableFilename(
        _ name: String, in directory: URL, reserved: Set<String> = [],
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> String {
        // 文件名来自远端或用户输入，不能借编号逻辑逃逸保存目录。
        guard !name.contains("/"), !name.contains("\\"), ![".", ".."].contains(name) else { return name }
        let file = URL(fileURLWithPath: name)
        let ext = file.pathExtension
        let stem = ext.isEmpty ? name : file.deletingPathExtension().lastPathComponent
        var candidate = name
        var number = 1
        while reserved.contains(candidate) || exists(directory.appendingPathComponent(candidate)) {
            candidate = stem + " (\(number))" + (ext.isEmpty ? "" : "." + ext)
            number += 1
        }
        return candidate
    }

    func mergeTrackers(for item: NewTaskLinkModel, in model: AppModel) async {
        guard item.canMergeTrackers, !item.isMergingTrackers,
              let id = item.duplicateTaskID, let engine = model.bitTorrent?.engine else { return }
        item.isMergingTrackers = true
        defer { item.isMergingTrackers = false }
        do {
            _ = try await engine.addTrackers(id, urls: item.trackers)
            item.duplicateMessage = String(localized: "tracker 已合并，将保留已有任务。")
            item.duplicateAcknowledged = true
        } catch {
            item.duplicateMessage = String(localized: "无法合并 tracker，已有任务不受影响。可保留已有任务并跳过本次重复项。")
        }
    }

    @discardableResult
    func appendTorrentFiles(_ urls: [URL]) -> Bool {
        let text = Self.torrentFileText(urls)
        guard !text.isEmpty else { return false }
        mergePrefillText(text)
        return true
    }

    static func torrentFileText(_ urls: [URL]) -> String {
        urls.filter { $0.isFileURL && $0.pathExtension.lowercased() == "torrent" }
            .map(\.absoluteString).joined(separator: "\n")
    }

    nonisolated static func droppedText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.isFileURL { return droppedURLText(url) }
        return SmartPasteParser.parse(trimmed).contains(where: { !$0.links.isEmpty }) ? trimmed : nil
    }

    nonisolated static func droppedURLText(_ url: URL) -> String? {
        guard url.isFileURL else {
            return SmartPasteParser.parse(url.absoluteString).contains(where: { !$0.links.isEmpty }) ? url.absoluteString : nil
        }
        if url.pathExtension.lowercased() == "torrent" { return url.absoluteString }
        guard url.pathExtension.lowercased() == "webloc" else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576,
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let text = plist["URL"] as? String, let link = URL(string: text), !link.isFileURL else { return nil }
        return droppedText(text)
    }

    private func parseInput() {
        let previousLinks = Dictionary(uniqueKeysWithValues: links.map { ($0.id, $0) })
        diskConfirmed = false
        diskWarning = nil
        diskCheckNote = nil
        needsDuplicateChoice = false
        duplicateChoice = nil
        inputRows = parser == nil ? SmartPasteParser.parse(inputText) : []
        var parsedContexts: [ParsedLink: DownloadRequestContext] = [:]
        for row in inputRows {
            for link in row.links { parsedContexts[link] = row.context }
        }
        var seen = Set<ParsedLink>()
        let parsed = (parser?(inputText) ?? inputRows.flatMap(\.links)).filter { seen.insert($0).inserted }
        links = parsed.map { link in
            let item = previousLinks[link] ?? NewTaskLinkModel(link: link, metadataProvider: metadataProvider)
            item.requestContext = contexts[link]?.requestContext ?? parsedContexts[link] ?? item.requestContext
            if previousLinks[link] == nil { item.checksumText = contexts[link]?.checksum?.aria2Value ?? "" }
            return item
        }
    }
}
