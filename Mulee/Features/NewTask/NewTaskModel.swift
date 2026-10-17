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
    // 自动编号是默认值，只有改成覆盖或询问时才需要说明 BT 与视频的同名处理。
    private(set) var showsEngineDuplicateNote = false
    private(set) var isChecking = false
    private(set) var links: [NewTaskLinkModel] = []
    var saveDirectory: URL {
        didSet { diskConfirmed = false }
    }
    private var lastCheckedBytes: Int64?
    var autoExtract: Bool
    private var contexts: [ParsedLink: NewTaskContext] = [:]
    private var hasPrefilledDirectory = false
    private var hasAppliedSettingsDefaults = false

    @ObservationIgnored private weak var appModel: AppModel?

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
    var downloadTaskCount: Int {
        links.filter { $0.duplicateMessage == nil }.reduce(0) { count, item in
            count + (item.requiresVideoSelection ? item.selectedVideoEntries.count : max(1, item.selectedVideoEntries.count))
        }
    }
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

    func applySettingsDefaults(from settings: SettingsModel) {
        // 设置默认值跟随草稿生命周期，不能在面板重建时覆盖用户的修改。
        guard !hasAppliedSettingsDefaults else { return }
        hasAppliedSettingsDefaults = true
        // 面板出现前可能已收到预填；只补默认值，不能替换草稿或覆盖交接指定的目录。
        if !hasPrefilledDirectory {
            saveDirectory = URL(filePath: settings.saveDirectory, directoryHint: .isDirectory)
        }
        autoExtract = settings.autoExtract
    }

    /// 从全局状态取走预填文本，追加到已有草稿；空预填不改变草稿。
    func consumePendingText(from model: AppModel) {
        appModel = model
        refreshDuplicateWarnings(in: model)
        let pendingText = model.pendingNewTaskText
        guard !pendingText.isEmpty else { return }
        if let directory = model.pendingNewTaskDirectory {
            saveDirectory = directory
            hasPrefilledDirectory = true
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
        inputText += separator + Self.readableText(text)
    }

    var downloadLinks: [ParsedLink] {
        links.flatMap { item in
            if item.requiresVideoSelection { return item.selectedVideoEntries.map(\.link) }
            return item.selectedVideoEntries.isEmpty ? [item.link] : item.selectedVideoEntries.map(\.link)
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
            context.videoOptions = item.link.kind == .video ? item.videoOutputOptions : nil
            context.videoFormatID = item.selectedVideoFormat?.id
            context.videoFormatVideoOnly = item.selectedVideoFormat?.videoOnly ?? false
            context.videoIdentity = item.videoIdentity
            expandedContexts[item.link] = context
            for entry in item.selectedVideoEntries {
                var entryContext = context
                entryContext.videoIdentity = entry.videoIdentity ?? (entry.url == item.videoFormatURL ? item.videoIdentity : nil)
                if item.showsPlaylistSubfolder, item.playlistSubfolder, let title = item.playlistTitle {
                    let folder = FileNameSanitizer.sanitize(title)
                    let rule = DownloadRule(name: "", subdirectory: folder)
                    if let directory = rule.saveDirectory(under: saveDirectory),
                       directory.resolvingSymlinksInPath().deletingLastPathComponent().pathComponents
                        == saveDirectory.resolvingSymlinksInPath().pathComponents {
                        entryContext.saveDirectory = directory
                    }
                }
                expandedContexts[entry.link] = entryContext
            }
        }
        model.addTasks(
            from: downloadLinks.filter { link in
                !links.contains { $0.duplicateMessage != nil && ($0.link == link || $0.selectedVideoEntries.contains { $0.link == link }) }
            }, autoExtract: autoExtract, directory: saveDirectory,
            filePriorities: filePriorities, torrentDownloadModes: torrentDownloadModes,
            videoEntries: videoEntries, contexts: expandedContexts, playAddedSound: true
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
        refreshDuplicateWarnings(in: model)
        await resolveDuplicateMetadata(in: model)
        guard inputText == originalText, saveDirectory == directory, !Task.isCancelled else { return false }
        needsDuplicateChoice = settings.duplicateAction == .ask && links.contains { $0.link.kind == .http }
        showsEngineDuplicateNote = settings.duplicateAction != .rename
            && links.contains { $0.link.kind == .bittorrent || $0.link.kind == .video }
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

    /// 解析完成即提示重复项，不能等到用户按下开始下载。
    func refreshDuplicateWarnings(in model: AppModel) {
        var seenHashes = Set<String>()
        for item in links {
            item.refreshExistingDownload(in: model.tasks)
            guard let hash = item.infoHash else { continue }
            let existing = NewTaskLinkModel.existingTorrent(infoHash: hash, tasks: model.tasks)
            let repeated = !seenHashes.insert(hash).inserted
            guard existing != nil || repeated else {
                item.duplicateMessage = nil
                item.duplicateTaskID = nil
                item.duplicateRecordID = nil
                item.duplicateIsPrivate = nil
                item.canMergeTrackers = false
                item.duplicateAcknowledged = false
                continue
            }
            let isDeleted = existing?.deletedAt != nil
            if item.duplicateRecordID != existing?.id || item.duplicateTaskID != existing?.engineTaskID
                || item.duplicateWasDeleted != isDeleted {
                item.duplicateIsPrivate = nil
                item.duplicateAcknowledged = false
            }
            item.duplicateWasDeleted = isDeleted
            item.duplicateRecordID = existing?.id
            item.duplicateTaskID = existing?.engineTaskID
            item.canMergeTrackers = false
            let message: String
            if existing?.deletedAt != nil {
                message = String(localized: "这个种子已在最近删除里，请恢复任务，或彻底删除后再添加。")
            } else if repeated, existing == nil {
                message = String(localized: "本次列表中已有相同种子。请保留第一项，跳过本次重复项。")
            } else if item.torrentInfo?.isPrivate == true || item.duplicateIsPrivate == true {
                message = String(localized: "这个私有种子已存在，不会合并 tracker。请使用已有任务。")
            } else if item.torrentInfo?.isPrivate == false || item.duplicateIsPrivate == false {
                item.canMergeTrackers = !item.trackers.isEmpty && item.duplicateTaskID != nil && model.bitTorrent != nil
                message = String(localized: "这个公开种子已存在。可合并本次 tracker，或保留已有任务。")
            } else {
                message = String(localized: "这个种子已存在，尚无法确认公开状态，不会合并 tracker。请使用已有任务。")
            }
            // 已确认的同一重复项可保留选择；回收站等状态变化则必须重新确认。
            if !item.duplicateAcknowledged { item.duplicateMessage = message }
        }
    }

    func resolveDuplicateMetadata(in model: AppModel) async {
        for item in links {
            guard let hash = item.infoHash,
                  let existing = NewTaskLinkModel.existingTorrent(infoHash: hash, tasks: model.tasks),
                  existing.deletedAt == nil, let id = existing.engineTaskID,
                  let engine = model.bitTorrent?.engine,
                  let info = try? await engine.taskInfo(id), info.hasMetadata else { continue }
            guard !Task.isCancelled, links.contains(where: { $0 === item }),
                  model.tasks.contains(where: { $0.id == existing.id && $0.deletedAt == nil && $0.engineTaskID == id }) else { continue }
            item.duplicateIsPrivate = info.isPrivate
        }
        guard !Task.isCancelled else { return }
        refreshDuplicateWarnings(in: model)
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
        urls.filter { $0.isFileURL && HTTPMetalink.isDownloadFile($0) }
            .map(\.path).joined(separator: "\n")
    }

    nonisolated static func droppedText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains(where: \.isNewline), let url = URL(string: trimmed), url.isFileURL {
            return droppedURLText(url)
        }
        return SmartPasteParser.parse(trimmed).contains(where: { !$0.links.isEmpty }) ? readableText(trimmed) : nil
    }

    nonisolated static func droppedURLText(_ url: URL) -> String? {
        guard url.isFileURL else {
            return SmartPasteParser.parse(url.absoluteString).contains(where: { !$0.links.isEmpty }) ? url.absoluteString : nil
        }
        guard url.host == nil || url.host == "" || url.host?.lowercased() == "localhost" else { return nil }
        if HTTPMetalink.isDownloadFile(url) { return url.path }
        guard ["webloc", "magnet"].contains(url.pathExtension.lowercased()) else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576,
              let data = try? Data(contentsOf: url) else { return nil }
        if url.pathExtension.lowercased() == "magnet" {
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            let links = SmartPasteParser.parse(text).flatMap(\.links)
            return links.isEmpty ? nil : readableText(links.map(\.original).joined(separator: "\n"))
        }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let text = plist["URL"] as? String, let link = URL(string: text), !link.isFileURL else { return nil }
        return droppedText(text)
    }

    nonisolated static func readableText(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line in
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: value), url.isFileURL,
                  url.host == nil || url.host == "" || url.host?.lowercased() == "localhost",
                  HTTPMetalink.isDownloadFile(url) else { return line }
            return url.path
        }.joined(separator: "\n")
    }

    private func parseInput() {
        let previousLinks = Dictionary(uniqueKeysWithValues: links.map { ($0.id, $0) })
        diskConfirmed = false
        diskWarning = nil
        diskCheckNote = nil
        needsDuplicateChoice = false
        showsEngineDuplicateNote = false
        duplicateChoice = nil
        inputRows = parser == nil ? SmartPasteParser.parse(inputText) : []
        var parsedContexts: [ParsedLink: DownloadRequestContext] = [:]
        for row in inputRows {
            for link in row.links { parsedContexts[link] = row.context }
        }
        var seen = Set<ParsedLink>()
        // 输入框显示可读路径，内部仍保留系统打开时的 file URL 身份，供监视文件夹确认与上下文匹配。
        let sourceLinks = parser?(inputText) ?? inputRows.flatMap(\.links).map { link -> ParsedLink in
            if case .torrentFile(let url, _) = link, url.isFileURL {
                return .torrentFile(url: url, original: url.absoluteString)
            }
            if case .http(let url, let decoded, _) = link, url.isFileURL, HTTPMetalink.recognizes(url) {
                return .http(url: url, decodedFromThunder: decoded, original: url.absoluteString)
            }
            return link
        }
        let parsed = sourceLinks.filter { seen.insert($0).inserted }
        links = parsed.map { link in
            let item = previousLinks[link] ?? NewTaskLinkModel(link: link, metadataProvider: metadataProvider)
            item.requestContext = contexts[link]?.requestContext ?? parsedContexts[link] ?? item.requestContext
            if previousLinks[link] == nil { item.checksumText = contexts[link]?.checksum?.aria2Value ?? "" }
            return item
        }
        if let appModel { refreshDuplicateWarnings(in: appModel) }
    }
}
