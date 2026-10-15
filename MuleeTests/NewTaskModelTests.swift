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
        let draft = NewTaskModel(parser: { _ in [NewTaskPreviewData.links[0]] })
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
        let draft = NewTaskModel(parser: { _ in sampleLinks })
        let torrent = try #require(draft.links.first)
        let video = try #require(draft.links.last)
        torrent.files?[0].isSelected = false
        video.videoQuality = .bestQuality
        video.danmakuToASS = false
        video.ccSubtitles = false

        draft.inputText = "继续粘贴"

        #expect(draft.links.first === torrent)
        #expect(draft.links.last === video)
        #expect(torrent.selectedSize == 512_048_000)
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

    @Test func defaultSaveDirectoryIsMuleeDownloads() {
        let draft = NewTaskModel(parser: { _ in [] })

        #expect(draft.saveDirectory == URL.homeDirectory.appending(path: "Downloads/Mulee", directoryHint: .isDirectory))
        #expect(draft.saveDirectoryLabel == "~/Downloads/Mulee")
    }
}
