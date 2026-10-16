import Foundation
import MuleeCore
import Testing
@testable import Mulee

@Suite @MainActor struct NewTaskModelTests {
    @Test func reparsingUpdatesLinkCountAndButtonAvailability() {
        let sampleLinks = NewTaskPreviewData.links
        let draft = NewTaskModel(parser: { text in
            text.isEmpty ? [] : Array(sampleLinks.prefix(text == "一个链接" ? 1 : 4))
        })
        #expect(draft.linkCount == 0)
        #expect(!draft.canStartDownload)

        draft.inputText = "四个链接"

        #expect(draft.linkCount == 4)
        #expect(draft.canStartDownload)
        #expect(draft.hasVideoLinks)

        draft.inputText = "一个链接"

        #expect(draft.linkCount == 1)
        #expect(!draft.hasVideoLinks)

        draft.inputText = ""

        #expect(draft.parsedLinks.isEmpty)
        #expect(!draft.canStartDownload)
    }

    @Test func exampleTorrentCalculatesSelectedAndTotalBytes() throws {
        let draft = NewTaskModel(parser: { _ in [NewTaskPreviewData.links[0]] }, metadataProvider: ExampleTorrentMetadataProvider())
        let item = try #require(draft.links.first)

        #expect(item.files?.count == 4)
        #expect(item.files?.filter(\.isSelected).count == 3)
        #expect(item.selectedSize == 2_912_048_000)
        #expect(item.totalSize == 8_412_048_000)

        item.files?[3].isSelected = true

        #expect(item.selectedSize == item.totalSize)

        item.files?[0].isSelected = false

        #expect(item.selectedSize == 6_012_048_000)

        for index in item.files?.indices ?? 0..<0 {
            item.files?[index].isSelected = false
        }

        #expect(item.selectedSize == 0)
        #expect(item.totalSize == 8_412_048_000)
    }

    @Test func unknownTorrentWaitsForMetadata() throws {
        let link = ParsedLink.magnet(infoHash: String(repeating: "a", count: 40), displayName: nil, original: "magnet:unknown")
        let draft = NewTaskModel(parser: { _ in [link] })
        let item = try #require(draft.links.first)

        #expect(item.files == nil)
        #expect(item.selectedSize == nil)
        #expect(item.totalSize == nil)
        #expect(item.detail == "磁力链接 · 正在获取元数据")
        #expect(draft.canStartDownload)
    }

    @Test func reparsingPreservesOptionsForUnchangedLinks() throws {
        let sampleLinks = NewTaskPreviewData.links
        let draft = NewTaskModel(parser: { _ in sampleLinks }, metadataProvider: ExampleTorrentMetadataProvider())
        let torrent = try #require(draft.links.first)
        let video = try #require(draft.links.last)
        #expect(torrent.sequentialDownload == false)
        #expect(torrent.firstLastPriority == false)
        #expect(draft.torrentDownloadModes.count == 1)
        torrent.sequentialDownload = true
        torrent.firstLastPriority = true
        torrent.files?[0].isSelected = false
        video.videoQuality = .bestQuality
        video.danmakuToASS = false
        video.ccSubtitles = false

        draft.inputText = "继续粘贴"

        #expect(draft.links.first === torrent)
        #expect(draft.links.last === video)
        #expect(torrent.selectedSize == 512_048_000)
        #expect(draft.torrentDownloadModes[torrent.link]?.sequentialDownload == true)
        #expect(draft.torrentDownloadModes[torrent.link]?.firstLastPriority == true)
        #expect(video.videoQuality == .bestQuality)
        #expect(!video.danmakuToASS)
        #expect(!video.ccSubtitles)
    }

    @Test func creatingTasksAddsParsedLinksAndAutoExtractPreference() {
        let sampleLinks = NewTaskPreviewData.links
        let app = AppModel(tasks: [])
        let draft = NewTaskModel(parser: { _ in sampleLinks })
        #expect(draft.autoExtract)
        draft.autoExtract = false

        draft.createTasks(in: app)

        #expect(app.tasks.count == 4)
        #expect(app.tasks.map(\.sourceLink) == sampleLinks.map(\.original))
        #expect(app.tasks.allSatisfy { !$0.postDownload.autoExtract })
        #expect(app.selectedTaskID == app.tasks.first?.id)

        draft.autoExtract = true
        draft.createTasks(in: app)

        #expect(app.tasks.count == 8)
        #expect(app.tasks.prefix(4).allSatisfy { $0.postDownload.autoExtract })
    }

    @Test func emptyDraftDoesNotCreateTasks() {
        let app = AppModel(tasks: [])
        let draft = NewTaskModel(parser: { _ in [] })

        draft.createTasks(in: app)

        #expect(app.tasks.isEmpty)
    }

    @Test func pendingTextIsConsumedOnceAndReparsed() {
        let sampleLinks = NewTaskPreviewData.links
        let app = AppModel(tasks: [])
        app.pendingNewTaskText = "来自菜单栏的链接"
        let draft = NewTaskModel(parser: { text in
            text == "来自菜单栏的链接" ? sampleLinks : []
        })

        draft.consumePendingText(from: app)

        #expect(draft.inputText == "来自菜单栏的链接")
        #expect(app.pendingNewTaskText.isEmpty)
        #expect(draft.linkCount == 4)

        draft.inputText = "用户编辑的草稿"
        draft.consumePendingText(from: app)

        #expect(draft.inputText == "用户编辑的草稿")
        #expect(app.pendingNewTaskText.isEmpty)
    }

    @Test func consumedPrefillSurvivesSheetRecreation() throws {
        let temporary = try TemporaryDefaults(prefix: "sheet-recreation.")
        defer { temporary.clean() }
        let settings = SettingsModel(defaults: temporary.defaults)
        let app = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        let text = "https://example.org/archive.zip"
        let link = try #require(LinkParser.parse(text).first)
        let sourcePage = try #require(URL(string: "https://example.org/page"))
        let directory = URL(filePath: "/tmp/fictional-handoff", directoryHint: .isDirectory)
        app.pendingNewTaskDirectory = directory
        app.pendingNewTaskContexts[link] = NewTaskContext(
            sourcePageURL: sourcePage, password: "fictional",
            requestContext: DownloadRequestContext(cookie: "session=fictional")
        )
        app.showNewTask(prefill: text)
        weak var originalDraft: NewTaskModel?
        do {
            let draft = app.prepareNewTaskDraft(settings: settings)
            originalDraft = draft
            draft.autoExtract = false
            try #require(draft.inputText == text)
            try #require(app.pendingNewTaskText.isEmpty)
        }

        // 模拟首个面板销毁，释放其局部强引用；重建时只能从全局状态恢复草稿。
        let rebuiltDraft = app.prepareNewTaskDraft(settings: settings)

        #expect(rebuiltDraft === originalDraft)
        #expect(rebuiltDraft.inputText == text)
        #expect(rebuiltDraft.saveDirectory == directory)
        #expect(rebuiltDraft.autoExtract == false)
        #expect(rebuiltDraft.links.first?.requestContext.cookie == "session=fictional")
        rebuiltDraft.createTasks(in: app)
        let task = try #require(app.tasks.first)
        #expect(task.sourcePageURL == sourcePage)
        #expect(app.pagePasswords[task.id] == "fictional")
    }

    @Test("重建保留用户目录与选项，追加预填只消费一次")
    func rebuiltSheetPreservesEditsAndAppendsNewPrefill() throws {
        let temporary = try TemporaryDefaults(prefix: "sheet-edits.")
        defer { temporary.clean() }
        let settings = SettingsModel(defaults: temporary.defaults)
        let app = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        let first = "https://example.org/first.zip"
        let second = "https://example.org/second.zip"
        app.showNewTask(prefill: first)
        let draft = app.prepareNewTaskDraft(settings: settings)
        let firstItem = try #require(draft.links.first)
        let directory = URL(filePath: "/tmp/fictional-user-directory", directoryHint: .isDirectory)
        draft.saveDirectory = directory
        draft.autoExtract = false
        firstItem.checksumText = String(repeating: "a", count: 64)
        app.showNewTask(prefill: second)

        let rebuiltDraft = app.prepareNewTaskDraft(settings: settings)
        app.prepareNewTaskDraft(settings: settings)

        #expect(rebuiltDraft === draft)
        #expect(rebuiltDraft.inputText == first + "\n" + second)
        #expect(rebuiltDraft.saveDirectory == directory)
        #expect(rebuiltDraft.autoExtract == false)
        #expect(rebuiltDraft.links.first === firstItem)
        #expect(rebuiltDraft.links.first?.checksumText == String(repeating: "a", count: 64))
        #expect(app.pendingNewTaskText.isEmpty)
    }

    @Test("取消或提交才结束草稿，下次打开重新取默认值", arguments: [false, true])
    func finishingDraftStartsFresh(_ submit: Bool) throws {
        let temporary = try TemporaryDefaults(prefix: "sheet-finish.")
        defer { temporary.clean() }
        let settings = SettingsModel(defaults: temporary.defaults)
        let app = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        app.showNewTask(prefill: "https://example.org/archive.zip")
        weak var previousDraft: NewTaskModel?
        do {
            let draft = app.prepareNewTaskDraft(settings: settings)
            previousDraft = draft
            draft.autoExtract = false
            if submit { draft.createTasks(in: app) }
        }

        app.finishNewTask()
        #expect(app.isShowingNewTask == false)
        settings.autoExtract = true
        app.showNewTask()
        let nextDraft = app.prepareNewTaskDraft(settings: settings)

        #expect(previousDraft == nil)
        #expect(nextDraft.inputText.isEmpty)
        #expect(nextDraft.links.isEmpty)
        #expect(nextDraft.autoExtract)
        #expect(app.tasks.count == (submit ? 1 : 0))
        #expect(app.pendingNewTaskText.isEmpty)
        #expect(app.pendingNewTaskDirectory == nil)
        #expect(app.pendingNewTaskContexts.isEmpty)
    }

    @Test func defaultSaveDirectoryIsMuleeDownloads() {
        let draft = NewTaskModel(parser: { _ in [] })

        #expect(draft.saveDirectory == URL.homeDirectory.appending(path: "Downloads/Mulee", directoryHint: .isDirectory))
        #expect(draft.saveDirectoryLabel == "~/Downloads/Mulee")
    }

    @Test("草稿使用传入的目录和解压默认值", arguments: [true, false])
    func injectedDefaults(autoExtract: Bool) {
        let directory = URL(filePath: "/tmp/自定义下载", directoryHint: .isDirectory)
        let draft = NewTaskModel(saveDirectory: directory, autoExtract: autoExtract)

        #expect(draft.saveDirectory == directory)
        #expect(draft.autoExtract == autoExtract)
    }

    @Test("合并预填文本保留草稿并按需补换行", arguments: [
        ("", "新链接", "新链接"),
        ("已有链接", "新链接", "已有链接\n新链接"),
        ("已有链接\n", "新链接", "已有链接\n新链接"),
        ("已有链接", "", "已有链接"),
        ("已有链接", "链接一\n链接二", "已有链接\n链接一\n链接二")
    ])
    func mergingPrefill(_ existing: String, _ prefill: String, _ expected: String) {
        let draft = NewTaskModel(inputText: existing)

        draft.mergePrefillText(prefill)

        #expect(draft.inputText == expected)
    }

    @Test func repeatedPendingTextAppendsAndPreservesExistingLinkOptions() throws {
        let first = "https://example.com/first.zip"
        let second = "https://example.com/second.zip"
        let app = AppModel(tasks: [])
        let draft = NewTaskModel(inputText: first)
        let originalItem = try #require(draft.links.first)

        app.showNewTask(prefill: second)
        draft.consumePendingText(from: app)

        #expect(draft.inputText == first + "\n" + second)
        #expect(app.pendingNewTaskText.isEmpty)
        #expect(draft.linkCount == 2)
        #expect(draft.links.first === originalItem)

        app.showNewTask(prefill: "https://example.com/third.zip")
        draft.consumePendingText(from: app)
        draft.consumePendingText(from: app)

        #expect(draft.inputText == first + "\n" + second + "\nhttps://example.com/third.zip")
        #expect(app.pendingNewTaskText.isEmpty)
        #expect(draft.linkCount == 3)
    }

    @Test("启动预填在面板初始化前后都保留", arguments: [false, true], [false, true])
    func startupPrefillSurvivesSheetPreparation(_ consumeBeforeAppearance: Bool, _ includesDirectory: Bool) throws {
        let temporary = try TemporaryDefaults(prefix: "startup-prefill.")
        defer { temporary.clean() }
        let settings = SettingsModel(defaults: temporary.defaults)
        settings.saveDirectory = "/tmp/fictional-downloads"
        settings.autoExtract = false
        let app = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        let magnet = "magnet:?xt=urn:btih:" + String(repeating: "a", count: 40)
        let second = "https://example.org/second.zip"
        let link = try #require(LinkParser.parse(second).first)
        let sourcePage = try #require(URL(string: "https://example.org/page"))
        app.showNewTask(prefill: magnet)
        app.pendingNewTaskContexts[link] = NewTaskContext(sourcePageURL: sourcePage, password: "fictional")
        if includesDirectory {
            app.pendingNewTaskDirectory = URL(filePath: "/tmp/fictional-intent", directoryHint: .isDirectory)
        }
        app.showNewTask(prefill: second)
        app.showNewTask()
        let draft = app.newTaskDraft

        // 模拟 onChange 先于 onAppear，预填已经从全局状态取走。
        if consumeBeforeAppearance { draft.consumePendingText(from: app) }
        let originalDraft = draft
        let earlyItem = draft.links.first
        earlyItem?.sequentialDownload = true
        app.prepareNewTaskDraft(settings: settings)

        #expect(draft === originalDraft)
        if let earlyItem {
            #expect(draft.links.first === earlyItem)
            #expect(draft.links.first?.sequentialDownload == true)
        }
        #expect(draft.inputText == magnet + "\n" + second)
        #expect(draft.linkCount == 2)
        #expect(draft.saveDirectory.path == (includesDirectory ? "/tmp/fictional-intent" : settings.saveDirectory))
        #expect(!draft.autoExtract)
        #expect(app.pendingNewTaskText.isEmpty)
        #expect(app.pendingNewTaskContexts.isEmpty)
        #expect(app.pendingNewTaskDirectory == nil)
        #expect(app.tasks.isEmpty)

        let originalItem = try #require(draft.links.first)
        originalItem.sequentialDownload = true
        app.showNewTask(prefill: "https://example.org/third.zip")
        draft.consumePendingText(from: app)
        app.prepareNewTaskDraft(settings: settings)

        #expect(draft.inputText == magnet + "\n" + second + "\nhttps://example.org/third.zip")
        #expect(draft.linkCount == 3)
        #expect(draft.links.first === originalItem)
        #expect(draft.links.first?.sequentialDownload == true)
        draft.createTasks(in: app)
        let task = try #require(app.tasks.first { $0.sourceLink == second })
        #expect(task.sourcePageURL == sourcePage)
        #expect(app.pagePasswords[task.id] == "fictional")
    }
}
