import Foundation
import MuleeCore
import Observation

/// 每个已识别链接的展示信息与独立选项。
@Observable
final class NewTaskLinkModel: Identifiable {
    let link: ParsedLink
    var files: [TorrentFile]?
    private(set) var torrentInfo: TorrentFileInfo?
    private var filteredJunkNames: Set<String> = []
    private var didFilterJunk = false
    private(set) var videoFormats: [YtDlpFormat] = []
    private(set) var videoMetadata: YtDlpVideoMetadata?
    private(set) var isLoadingVideoFormats = false
    private(set) var videoFormatsError: String?
    private var didLoadVideoFormats = false
    private var loadedVideoFormatURL: URL?
    var videoFormatID = ""
    var videoSubtitleLanguages: Set<String> = []
    var didSelectSubtitleLanguages = false
    var videoSectionStart = ""
    var videoSectionEnd = ""

    var duplicateRecordID: UUID?
    var duplicateIsPrivate: Bool?
    var duplicateWasDeleted = false
    var duplicateTaskID: String?
    var duplicateMessage: String?
    var canMergeTrackers = false
    var duplicateAcknowledged = false
    var isMergingTrackers = false
    private(set) var torrentName: String?
    private(set) var metadataError: String?
    private(set) var videoParts: [YtDlpPlaylistEntry] = []
    var selectedVideoParts: Set<URL> = []
    var videoIdentity: String?
    var playlistSubfolder = true
    var existingDownloadID: UUID?
    var existingDownloadMessage: String?
    var existingDownloadFile: URL?
    private(set) var isLoadingVideoParts = false
    private(set) var videoPartsError: String?
    private var didLoadVideoParts = false
    var videoQuality = NewTaskVideoQuality.compatible1080p
    var danmakuToASS = true
    var ccSubtitles = true
    var sequentialDownload = false
    var firstLastPriority = false
    var checksumText = ""
    var requestContext = DownloadRequestContext()

    var checksum: DownloadChecksum? { DownloadChecksum.parse(checksumText) }
    var hasInvalidChecksum: Bool { !checksumText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && checksum == nil }

    var id: ParsedLink { link }

    init(link: ParsedLink, metadataProvider: (any TorrentMetadataProvider)? = nil) {
        self.link = link
        if case .magnet(let infoHash, _, _) = link {
            files = metadataProvider?.files(for: infoHash)
        }
        if case .torrentFile(let url, _) = link, url.isFileURL {
            do {
                let info = try TorrentFileInfo.parse(data: Data(contentsOf: url))
                torrentInfo = info
                torrentName = info.name
                files = info.files.map { TorrentFile(name: $0.path, size: $0.size) }
            } catch {
                metadataError = String(localized: "无法读取种子文件，请重新选择完整的 .torrent 文件")
            }
        }
    }

    var infoHash: String? {
        if case .magnet(let hash, _, _) = link { return hash.lowercased() }
        return torrentInfo?.infoHash
    }

    static func existingTorrent(infoHash: String, tasks: [DownloadTask]) -> DownloadTask? {
        tasks.first { task in
            guard task.kind == .bittorrent else { return false }
            if task.engineTaskID?.lowercased() == infoHash.lowercased() { return true }
            return SmartPasteParser.parse(task.sourceLink).flatMap(\.links).contains { link in
                NewTaskLinkModel(link: link).infoHash?.lowercased() == infoHash.lowercased()
            }
        }
    }

    var trackers: [String] {
        if let info = torrentInfo { return info.trackers }
        guard case .magnet(_, _, let original) = link else { return [] }
        return URLComponents(string: original)?.queryItems?.filter { $0.name == "tr" }.compactMap(\.value) ?? []
    }

    func applyJunkFilter(_ configuration: TorrentEngineSettings) {
        guard !didFilterJunk, files != nil else { return }
        didFilterJunk = true
        for index in files?.indices ?? 0..<0 {
            guard let file = files?[index], configuration.isJunkFile(path: file.name) else { continue }
            filteredJunkNames.insert(file.name)
            files?[index].isSelected = false
        }
    }

    var skippedJunkCount: Int {
        files?.filter { filteredJunkNames.contains($0.name) && !$0.isSelected }.count ?? 0
    }

    var audioOnly: Bool { videoFormatID == "mulee:audio" }

    var videoSectionError: String? {
        guard selectedVideoParts.count <= 1, !videoSectionStart.isEmpty || !videoSectionEnd.isEmpty else { return nil }
        do {
            _ = try YtDlpTimeSection(start: videoSectionStart, end: videoSectionEnd)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    var videoOutputOptions: YtDlpTaskOptions {
        let section = selectedVideoParts.count <= 1
            ? try? YtDlpTimeSection(start: videoSectionStart, end: videoSectionEnd) : nil
        return YtDlpTaskOptions(
            subtitleLanguages: didSelectSubtitleLanguages || videoMetadata != nil ? videoSubtitleLanguages.sorted() : nil,
            audioOnly: audioOnly, section: section
        )
    }

    var selectedVideoFormat: YtDlpFormat? { videoFormats.first { $0.id == videoFormatID } }

    var videoSiteKey: String? {
        guard case .video(let url, let site, _) = link else { return nil }
        switch site {
        case .youtube: return "youtube.com"
        case .bilibili: return "bilibili.com"
        case .other: return url.host?.lowercased()
        }
    }

    @_disfavoredOverload
    func loadVideoFormats(
        remembered: String? = nil, using provider: (URL, VideoSite) async throws -> YtDlpVideoMetadata
    ) async {
        await loadVideoFormats(remembered: remembered) { url, site -> [YtDlpFormat] in
            let metadata = try await provider(url, site)
            try Task.checkCancellation()
            guard self.videoFormatURL == url else { throw CancellationError() }
            self.videoMetadata = metadata
            self.videoIdentity = metadata.videoIdentity
            return metadata.formats
        }
    }

    func loadVideoFormats(
        remembered: String? = nil, using provider: (URL, VideoSite) async throws -> [YtDlpFormat]
    ) async {
        guard case .video(_, let site, _) = link, let url = videoFormatURL,
              !didLoadVideoFormats || loadedVideoFormatURL != url else { return }
        didLoadVideoFormats = true
        loadedVideoFormatURL = url
        videoFormats = []
        videoMetadata = nil
        videoIdentity = nil
        videoFormatsError = nil
        isLoadingVideoFormats = true
        defer { if loadedVideoFormatURL == url { isLoadingVideoFormats = false } }
        do {
            let formats = try await provider(url, site)
            try Task.checkCancellation()
            guard videoFormatURL == url else { throw CancellationError() }
            videoFormats = formats
            if let remembered, formats.contains(where: { $0.id == remembered }) { videoFormatID = remembered }
        } catch is CancellationError {
            if loadedVideoFormatURL == url { didLoadVideoFormats = false }
        } catch {
            guard loadedVideoFormatURL == url else { return }
            videoFormatID = ""
            videoFormatsError = (error as? YtDlpFormats.ListingError)?.errorDescription
                ?? String(localized: "无法读取视频格式，仍可跟随全局设置添加。")
        }
    }

    var knownDownloadSize: Int64? {
        if let selectedSize { return selectedSize }
        if case .ed2k(_, let size, _, _) = link { return size }
        return selectedVideoFormat?.size
    }

    var filePriorities: [Int]? { files?.map { $0.isSelected ? 4 : 0 } }

    var canStart: Bool {
        !hasInvalidChecksum && videoSectionError == nil && !isLoadingVideoParts && (!requiresVideoSelection || !selectedVideoEntries.isEmpty)
            && metadataError == nil && (files == nil || files?.contains(where: \.isSelected) == true)
    }

    var requiresVideoSelection: Bool { link.playlistID != nil || videoParts.count > 1 }

    var isPureVideoPlaylist: Bool { link.playlistID != nil && link.youtubeVideoID == nil }

    var videoFormatURL: URL? {
        if link.playlistID != nil { return selectedVideoEntries.first?.url ?? (isPureVideoPlaylist ? nil : link.singleVideoURL) }
        return link.singleVideoURL
    }

    var playlistTitle: String? {
        videoParts.first?.playlistTitle ?? (link.playlistID == nil ? nil : String(localized: "播放列表"))
    }

    var showsPlaylistSubfolder: Bool {
        link.playlistID != nil && selectedVideoEntries.count >= 2
    }

    func loadVideoParts(
        using provider: (URL) async throws -> [YtDlpPlaylistEntry]
    ) async {
        guard case .video(let url, let site, _) = link, !didLoadVideoParts,
              site == .bilibili || (site == .youtube && link.playlistID != nil) else { return }
        didLoadVideoParts = true
        isLoadingVideoParts = true
        defer { isLoadingVideoParts = false }
        do {
            let parts = try await provider(url)
            try Task.checkCancellation()
            videoParts = parts
            if site == .youtube {
                selectedVideoParts = Set(parts.filter { $0.link.youtubeVideoID == link.youtubeVideoID && link.youtubeVideoID != nil }.map(\.id))
                return
            }
            let current = YtDlpPlaylistEntry.selectedPart(in: url)
            let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let matching = parts.first {
                $0.url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == path
                    && YtDlpPlaylistEntry.selectedPart(in: $0.url) == current
            }
            selectedVideoParts = Set(matching.map { [$0.id] } ?? parts.filter { $0.index == current }.map(\.id))
            if selectedVideoParts.isEmpty, let first = parts.first { selectedVideoParts.insert(first.id) }
        } catch is CancellationError {
            didLoadVideoParts = false
        } catch {
            videoPartsError = link.playlistID != nil
                ? String(localized: "无法获取视频列表，请重新打开面板后重试")
                : String(localized: "无法获取视频列表，仍可下载当前视频")
        }
    }

    var selectedVideoEntries: [YtDlpPlaylistEntry] {
        videoParts.filter { selectedVideoParts.contains($0.id) }
    }

    func refreshExistingDownload(in tasks: [DownloadTask]) {
        let currentIdentity = link.playlistID == nil || selectedVideoEntries.contains(where: { $0.url == loadedVideoFormatURL })
            ? videoIdentity : nil
        let identities = Set(selectedVideoEntries.compactMap(\.videoIdentity) + (currentIdentity.map { [$0] } ?? []))
        let existing = tasks.first { task in
            guard task.deletedAt == nil, task.kind == link.kind else { return false }
            if link.kind == .video {
                return task.videoIdentity.map { identities.contains($0) } ?? false
            }
            guard case .http(let url, _, _) = link,
                  let candidate = Self.httpURLWithoutFragment(url) else { return false }
            return LinkParser.parse(task.sourceLink).contains { source in
                guard case .http(let previous, _, _) = source else { return false }
                return Self.httpURLWithoutFragment(previous) == candidate
            }
        }
        existingDownloadID = existing?.id
        existingDownloadMessage = existing.map { _ in
            link.kind == .video ? String(localized: "这个视频已在任务列表里") : String(localized: "这个链接下载过")
        }
        existingDownloadFile = existing?.savePath.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    private static func httpURLWithoutFragment(_ url: URL) -> URL? {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.url
    }

    func canDeselect(_ file: TorrentFile) -> Bool {
        !file.isSelected || (files?.filter(\.isSelected).count ?? 0) > 1
    }

    var selectedSize: Int64? {
        files?.filter(\.isSelected).reduce(0) { $0 + $1.size }
    }

    var totalSize: Int64? {
        files?.reduce(0) { $0 + $1.size }
    }

    var typeLabel: String {
        switch link {
        case .magnet, .torrentFile: "BT"
        case .ed2k: "ED2K"
        case .http: "HTTP"
        case .video: String(localized: "视频")
        }
    }

    var name: String {
        switch link {
        case .magnet(let infoHash, let displayName, _):
            displayName ?? infoHash
        case .torrentFile(let url, _):
            torrentName ?? url.lastPathComponent
        case .ed2k(let fileName, _, _, _):
            fileName
        case .http(let url, _, _):
            requestContext.suggestedFilename ?? (url.lastPathComponent.isEmpty ? (url.host() ?? url.absoluteString) : url.lastPathComponent)
        case .video(let url, _, _):
            url.absoluteString
        }
    }

    var detail: String {
        switch link {
        case .magnet:
            String(localized: "磁力链接 · 正在获取元数据")
        case .torrentFile:
            if let metadataError {
                metadataError
            } else if let files {
                String(localized: "BT 种子文件 · \(files.count) 个文件")
            } else {
                String(localized: "BT 种子文件")
            }
        case .ed2k:
            String(localized: "电驴链接 · 冷门资源可能需要长时间等待来源")
        case .http(let url, let decodedFromThunder, _):
            decodedFromThunder ? String(localized: "迅雷链接已解析为 \(url.absoluteString)") : String(localized: "直链 · \(url.host() ?? url.absoluteString)")
        case .video(_, let site, _):
            String(localized: "\(site.displayName) · 视频链接")
        }
    }

    var sizeDescription: String {
        if let selectedSize, let totalSize {
            return "\(selectedSize.formatted(.byteCount(style: .file))) / \(totalSize.formatted(.byteCount(style: .file)))"
        }
        if case .ed2k(_, let size, _, _) = link {
            return size.formatted(.byteCount(style: .file))
        }
        return String(localized: "大小未知")
    }
}
