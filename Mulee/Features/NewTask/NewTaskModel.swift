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

    private let parser: (String) -> [ParsedLink]
    private let metadataProvider: any TorrentMetadataProvider

    init(
        inputText: String = "",
        saveDirectory: URL = URL.homeDirectory.appending(path: "Downloads/Mulee", directoryHint: .isDirectory),
        autoExtract: Bool = true,
        parser: @escaping (String) -> [ParsedLink] = LinkParser.parse,
        metadataProvider: any TorrentMetadataProvider = ExampleTorrentMetadataProvider()
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
    var canStartDownload: Bool { !links.isEmpty }
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
        mergePrefillText(pendingText)
        model.pendingNewTaskText = ""
    }

    func mergePrefillText(_ text: String) {
        guard !text.isEmpty else { return }
        let separator = inputText.isEmpty || inputText.hasSuffix("\n") ? "" : "\n"
        inputText += separator + text
    }

    func createTasks(in model: AppModel) {
        guard canStartDownload else { return }
        model.addTasks(from: parsedLinks, autoExtract: autoExtract, directory: saveDirectory)
    }

    private func parseInput() {
        let previousLinks = Dictionary(uniqueKeysWithValues: links.map { ($0.id, $0) })
        links = parser(inputText).map { link in
            previousLinks[link] ?? NewTaskLinkModel(link: link, metadataProvider: metadataProvider)
        }
    }
}
