import Foundation
import MuleeCore
import Observation

/// 新建下载草稿。解析器可注入，面板不负责实现链接识别。
@Observable
final class NewTaskModel {
    var inputText: String {
        didSet { parseInput() }
    }
    private(set) var links: [NewTaskLinkModel] = []
    var saveDirectory: URL
    var autoExtract: Bool
    private var contexts: [ParsedLink: NewTaskContext] = [:]

    private let parser: (String) -> [ParsedLink]
    private let metadataProvider: (any TorrentMetadataProvider)?

    init(
        inputText: String = "",
        saveDirectory: URL = URL.homeDirectory.appending(path: "Downloads/Mulee", directoryHint: .isDirectory),
        autoExtract: Bool = true,
        parser: @escaping (String) -> [ParsedLink] = LinkParser.parse,
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
    var canStartDownload: Bool { !links.isEmpty && links.allSatisfy(\.canStart) }
    var filePriorities: [ParsedLink: [Int]] {
        Dictionary(uniqueKeysWithValues: links.compactMap { item in
            item.filePriorities.map { (item.link, $0) }
        })
    }
    var hasVideoLinks: Bool { links.contains { $0.link.kind == .video } }

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
        contexts.merge(model.pendingNewTaskContexts) { _, new in new }
        model.pendingNewTaskContexts = [:]
        mergePrefillText(pendingText)
        model.pendingNewTaskText = ""
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "MuleeOpenURLDiagnostics") {
            FileHandle.standardOutput.write(Data("Mulee OpenURL draft: \(inputText)\n".utf8))
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
        // TODO: 把逐任务画质和字幕选项传给视频引擎；当前使用全局设置。
        var expandedContexts = contexts
        for item in links {
            for entry in item.selectedVideoEntries { expandedContexts[entry.link] = contexts[item.link] }
        }
        model.addTasks(
            from: downloadLinks, autoExtract: autoExtract, directory: saveDirectory,
            filePriorities: filePriorities, videoEntries: videoEntries, contexts: expandedContexts
        )
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

    private func parseInput() {
        let previousLinks = Dictionary(uniqueKeysWithValues: links.map { ($0.id, $0) })
        links = parser(inputText).map { link in
            previousLinks[link] ?? NewTaskLinkModel(link: link, metadataProvider: metadataProvider)
        }
    }
}
