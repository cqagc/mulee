import AppKit
import Foundation
import MuleeCore
import Testing
@testable import Mulee

@Suite @MainActor struct NewTaskSmartPasteTests {
    @Test func droppedMagnetFileAndWeblocUseSharedParserAndAppendDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let magnet = "magnet:?xt=urn:btih:" + String(repeating: "a", count: 40)
        let magnetFile = root.appendingPathComponent("链接.magnet")
        try Data(magnet.utf8).write(to: magnetFile)
        #expect(NewTaskModel.droppedURLText(magnetFile) == magnet)
        let webloc = root.appendingPathComponent("sample.webloc")
        try PropertyListSerialization.data(fromPropertyList: ["URL": "https://example.com/drop.zip"], format: .xml, options: 0).write(to: webloc)
        let app = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        app.showNewTask(prefill: "https://example.com/first.zip")
        app.newTaskDraft.consumePendingText(from: app)
        let provider = NSItemProvider(contentsOf: webloc)!
        #expect(OpenURLDropHandler.accept([provider], model: app))
        for _ in 0..<100 where app.pendingNewTaskText.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        app.newTaskDraft.consumePendingText(from: app)
        #expect(app.newTaskDraft.linkCount == 2)
        #expect(app.newTaskDraft.inputText.contains("https://example.com/drop.zip"))
        #expect(app.isShowingNewTask)
        #expect(app.tasks.isEmpty)
    }

    @Test func localTorrentPrefillUsesReadablePathAndKeepsLiteralFilename() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("拖我 [1-3] #100% 测试.torrent")
        try Data("d4:infod6:lengthi1e4:name6:sampleee".utf8).write(to: file)
        let draft = NewTaskModel()
        #expect(draft.appendTorrentFiles([file]))
        #expect(draft.inputText == file.path)
        #expect(draft.parsedLinks == LinkParser.parse(file.absoluteString))
        #expect(draft.linkCount == 1)
        #expect(draft.links.first?.metadataError == nil)
        draft.inputText = file.path
        #expect(draft.linkCount == 1)
        #expect(draft.links.first?.metadataError == nil)
        let app = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        app.showNewTask(prefill: file.absoluteString)
        let opened = NewTaskModel()
        opened.consumePendingText(from: app)
        #expect(opened.inputText == file.path)
        #expect(opened.links.first?.metadataError == nil)
    }

    @Test(arguments: [false, true])
    func duplicateMagnetAppearsBeforeStarting(deleted: Bool) throws {
        let text = "magnet:?xt=urn:btih:" + String(repeating: "b", count: 40)
        var task = DownloadTask(link: try #require(LinkParser.parse(text).first), autoExtract: false)
        if deleted { task.deletedAt = .now }
        let app = AppModel(tasks: [task], preventsSleepWhileDownloading: false)
        app.showNewTask(prefill: text)
        app.newTaskDraft.consumePendingText(from: app)
        let item = try #require(app.newTaskDraft.links.first)
        #expect(item.duplicateMessage != nil)
        if deleted { #expect(item.duplicateMessage?.contains("最近删除") == true) }
        #expect(!item.duplicateAcknowledged)
    }

    @Test func localTorrentDuplicateAppearsImmediatelyAfterTyping() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sample.torrent")
        try Data("d4:infod6:lengthi1e4:name6:sampleee".utf8).write(to: file)
        let parsed = NewTaskLinkModel(link: try #require(LinkParser.parse(file.absoluteString).first))
        let hash = try #require(parsed.infoHash)
        let existing = try #require(LinkParser.parse("magnet:?xt=urn:btih:" + hash).first)
        let app = AppModel(tasks: [DownloadTask(link: existing, autoExtract: false)], preventsSleepWhileDownloading: false)
        app.showNewTask(prefill: "https://example.com/first.zip")
        app.newTaskDraft.consumePendingText(from: app)
        app.newTaskDraft.inputText = file.path
        #expect(app.newTaskDraft.links.first?.duplicateMessage != nil)
    }

    @Test func pasteboardMixedFilesAndTextPreserveOrderAndOnlyPrefill() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let torrent = root.appendingPathComponent("中文 # 测试.torrent")
        try Data("d4:infod6:lengthi1e4:name6:sampleee".utf8).write(to: torrent)
        let magnet = "magnet:?xt=urn:btih:" + String(repeating: "c", count: 40)
        let file = root.appendingPathComponent("sample.magnet")
        try Data(magnet.utf8).write(to: file)
        let webloc = root.appendingPathComponent("sample.webloc")
        let remote = "https://example.com/drop.zip"
        try PropertyListSerialization.data(fromPropertyList: ["URL": remote], format: .binary, options: 0).write(to: webloc)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var items: [NSPasteboardItem] = []
        for (type, value) in [(NSPasteboard.PasteboardType.fileURL, torrent.absoluteString),
                              (.fileURL, file.absoluteString), (.fileURL, webloc.absoluteString),
                              (.URL, "https://example.com/url.zip"), (.string, "https://example.com/string.zip")] {
            let item = NSPasteboardItem()
            item.setString(value, forType: type)
            items.append(item)
        }
        #expect(pasteboard.writeObjects(items))
        let expected = [torrent.path, magnet, remote, "https://example.com/url.zip", "https://example.com/string.zip"]
        #expect(OpenURLDropHandler.text(from: pasteboard)?.components(separatedBy: "\n") == expected)
        #expect(OpenURLDropHandler.text(from: torrent as Any) == torrent.path)
        #expect(OpenURLDropHandler.text(from: Data(remote.utf8) as Any) == remote)
        #expect(OpenURLDropHandler.text(from: "invalid" as Any) == nil)
        #expect(NewTaskModel.droppedText(torrent.absoluteString + "\n" + remote) == torrent.path + "\n" + remote)
        #expect(NewTaskModel.droppedURLText(URL(string: "file://example.com/tmp/private.torrent")!) == nil)
        let app = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        #expect(OpenURLDropHandler.accept(pasteboard, model: app))
        #expect(app.isShowingNewTask)
        app.newTaskDraft.consumePendingText(from: app)
        #expect(app.newTaskDraft.linkCount == 5)
        #expect(app.tasks.isEmpty)
    }

    @Test func duplicateWarningFollowsHistoryChangesWithoutStarting() throws {
        let text = "magnet:?xt=urn:btih:" + String(repeating: "d", count: 40)
        let task = DownloadTask(link: try #require(LinkParser.parse(text).first), autoExtract: false)
        let app = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        app.showNewTask(prefill: text)
        app.newTaskDraft.consumePendingText(from: app)
        let item = try #require(app.newTaskDraft.links.first)
        #expect(item.duplicateMessage == nil)
        app.tasks = [task]
        #expect(item.duplicateMessage != nil)
        item.duplicateAcknowledged = true
        app.tasks[0].deletedAt = .now
        #expect(item.duplicateMessage?.contains("最近删除") == true)
        #expect(!item.duplicateAcknowledged)
        app.tasks.removeAll()
        #expect(item.duplicateMessage == nil)
        #expect(!item.canMergeTrackers)
    }

    @Test func pasteCarriesRequestContextAndDoesNotPersistCookies() throws {
        let draft = NewTaskModel(inputText: "curl https://example.com/file.zip -H 'X-Test: sample' -b 'session=sample' -A Example")
        let item = try #require(draft.links.first)
        #expect(item.requestContext.cookie == "session=sample")
        #expect(item.requestContext.headers["X-Test"] == "sample")
        #expect(draft.inputRows.count == 1)
        let app = AppModel(tasks: [])
        draft.createTasks(in: app)
        #expect(app.tasks.first?.requestContext?.cookie == nil)
        #expect(app.tasks.first?.requestContext?.userAgent == "Example")
        #expect(!String(decoding: try JSONEncoder().encode(app.tasks), as: UTF8.self).contains("session=sample"))
    }

    @Test func invalidLinesStayVisibleWithoutEnablingDownload() {
        let draft = NewTaskModel(inputText: "curl https://example.com/a | cat\n无效内容")
        #expect(draft.inputRows.count == 2)
        #expect(!draft.canStartDownload)
        #expect(draft.links.isEmpty)
        draft.inputText = "https://example.com/[01-03].zip"
        #expect(draft.linkCount == 3)
        #expect(draft.canStartDownload)
    }

    @Test func diskConfirmationIsBoundToSizeAndDirectory() throws {
        let draft = NewTaskModel(parser: { _ in NewTaskPreviewData.links }, metadataProvider: ExampleTorrentMetadataProvider())
        #expect(!draft.checkDisk { size, _ in size > 0 })
        #expect(draft.diskWarning != nil)
        draft.diskConfirmed = true
        #expect(draft.checkDisk { _, _ in true })
        draft.links.first?.files?[0].isSelected = false
        #expect(!draft.checkDisk { _, _ in true })
        draft.diskConfirmed = true
        draft.saveDirectory = URL(filePath: "/tmp/another-download-directory")
        #expect(!draft.checkDisk { _, _ in true })
        #expect(draft.checkDisk { _, _ in false })
        #expect(draft.diskWarning == nil)
        #expect(draft.checkDisk { _, _ in throw CocoaError(.fileReadNoPermission) })
        #expect(draft.diskCheckNote != nil)
    }

    @Test func duplicateFilenameUsesParenthesizedNumberAndPreservesExtension() {
        let directory = URL(filePath: "/tmp/download-test")
        let occupied: Set<String> = ["sample.zip", "sample (1).zip"]
        #expect(NewTaskModel.availableFilename("sample.zip", in: directory, exists: { occupied.contains($0.lastPathComponent) }) == "sample (2).zip")
        #expect(NewTaskModel.availableFilename("README", in: directory, reserved: ["README"], exists: { _ in false }) == "README (1)")
        #expect(NewTaskModel.availableFilename("sample.tar.gz", in: directory, reserved: ["sample.tar.gz"], exists: { _ in false }) == "sample.tar (1).gz")
    }

    @Test func junkFilteringSharesRulesAndManualSelectionSurvives() throws {
        let item = NewTaskLinkModel(link: NewTaskPreviewData.links[0])
        item.files = [TorrentFile(name: "sample/data.bin", size: 100), TorrentFile(name: "sample/广告.txt", size: 2),
                      TorrentFile(name: "sample/SITE.URL", size: 3)]
        item.applyJunkFilter(TorrentEngineSettings())
        #expect(item.skippedJunkCount == 2)
        #expect(item.selectedSize == 100)
        item.files?[1].isSelected = true
        item.applyJunkFilter(TorrentEngineSettings())
        #expect(item.skippedJunkCount == 1)
        #expect(item.filePriorities == [4, 4, 0])
    }

    @Test func videoFormatRememberingAndFailureFallbackDoNotBlockAdding() async throws {
        let link = try #require(LinkParser.parse("https://www.youtube.com/watch?v=example").first)
        let formats = try YtDlpFormats.parse(Data(#"{"formats":[{"format_id":"720","height":720,"vcodec":"avc1","acodec":"aac","filesize":500}]}"#.utf8))
        let item = NewTaskLinkModel(link: link)
        #expect(item.videoFormatID.isEmpty)
        await item.loadVideoFormats(remembered: "720") { _, _ in formats }
        #expect(item.selectedVideoFormat?.id == "720")
        #expect(item.knownDownloadSize == 500)
        #expect(item.videoSiteKey == "youtube.com")
        #expect(item.canStart)
        let failed = NewTaskLinkModel(link: link)
        await failed.loadVideoFormats(remembered: "720") { _, _ in throw YtDlpFormats.ListingError.login }
        #expect(failed.videoFormatID.isEmpty)
        #expect(failed.videoFormatsError?.contains("登录") == true)
        #expect(failed.canStart)
        let stale = NewTaskLinkModel(link: link)
        await stale.loadVideoFormats(remembered: "missing") { _, _ in formats }
        #expect(stale.selectedVideoFormat == nil)
        #expect(stale.canStart)
    }

    @Test func duplicateTorrentRequiresAcknowledgmentAndSkipsNewTask() async throws {
        let hash = String(repeating: "a", count: 40)
        let link = "magnet:?xt=urn:btih:" + hash
        let app = AppModel(tasks: [DownloadTask(link: try #require(LinkParser.parse(link).first), autoExtract: false)])
        let draft = NewTaskModel(inputText: link + "&tr=https://tracker.example.com/announce")
        let temporaryDefaults = try TemporaryDefaults(prefix: "newtask.")
        defer { temporaryDefaults.clean() }
        let settings = SettingsModel(defaults: temporaryDefaults.defaults)
        #expect(await draft.checkBeforeAdding(in: app, settings: settings) == false)
        let item = try #require(draft.links.first)
        #expect(item.duplicateMessage != nil)
        #expect(!item.canMergeTrackers)
        item.duplicateAcknowledged = true
        #expect(await draft.checkBeforeAdding(in: app, settings: settings))
        draft.createTasks(in: app)
        #expect(app.tasks.count == 1)
    }

    @Test func askPolicyResolvesIntoConcreteHTTPOptions() async throws {
        let draft = NewTaskModel(inputText: "https://example.com/sample.zip")
        let app = AppModel(tasks: [])
        let temporaryDefaults = try TemporaryDefaults(prefix: "newtask.")
        defer { temporaryDefaults.clean() }
        let settings = SettingsModel(defaults: temporaryDefaults.defaults)
        settings.duplicateAction = .ask
        #expect(await draft.checkBeforeAdding(in: app, settings: settings) == false)
        #expect(draft.needsDuplicateChoice)
        draft.duplicateChoice = .overwrite
        #expect(await draft.checkBeforeAdding(in: app, settings: settings))
        #expect(draft.links.first?.requestContext.duplicateAction == .overwrite)
    }

    @Test func settingsDefaultsAndStoredFormatDictionary() throws {
        let temporaryDefaults = try TemporaryDefaults(prefix: "newtask.")
        defer { temporaryDefaults.clean() }
        let settings = SettingsModel(defaults: temporaryDefaults.defaults)
        #expect(settings.duplicateAction == .rename)
        #expect(settings.videoFormatChoiceBySite.isEmpty)
        settings.videoFormatChoiceBySite["example.com"] = "720"
        #expect(SettingsModel(defaults: temporaryDefaults.defaults).videoFormatChoiceBySite["example.com"] == "720")
        settings.duplicateAction = .overwrite
        #expect(SettingsModel(defaults: temporaryDefaults.defaults).duplicateAction == .overwrite)
    }

    @Test func dropsOnlyPrefillAndWeblocIsReadAsAURL() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sample.webloc")
        let url = "https://example.com/sample.zip"
        try PropertyListSerialization.data(fromPropertyList: ["URL": url], format: .xml, options: 0).write(to: file)
        #expect(NewTaskModel.droppedURLText(file) == url)
        #expect(NewTaskModel.droppedText("file:///tmp/sample.torrent") == "/tmp/sample.torrent")
        #expect(NewTaskModel.droppedText("invalid") == nil)
        #expect(NewTaskModel.droppedURLText(root.appendingPathComponent("sample.txt")) == nil)
        let app = AppModel(tasks: [])
        app.showNewTask(prefill: try #require(NewTaskModel.droppedURLText(file)))
        #expect(app.isShowingNewTask)
        #expect(app.pendingNewTaskText == url)
        #expect(app.tasks.isEmpty)
        try PropertyListSerialization.data(fromPropertyList: ["URL": "file:///tmp/sample.webloc"], format: .xml, options: 0).write(to: file)
        #expect(NewTaskModel.droppedURLText(file) == nil)
    }


    @Test func privateDuplicateNeverOffersTrackerMerge() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("private.torrent")
        try Data("d4:infod6:lengthi1e4:name6:sample7:privatei1eee".utf8).write(to: file)
        let draft = NewTaskModel(inputText: file.absoluteString)
        let item = try #require(draft.links.first)
        var task = DownloadTask(link: item.link, autoExtract: false)
        task.engineTaskID = item.infoHash
        let app = AppModel(tasks: [task])
        let temporaryDefaults = try TemporaryDefaults(prefix: "newtask.")
        defer { temporaryDefaults.clean() }
        let settings = SettingsModel(defaults: temporaryDefaults.defaults)
        #expect(await draft.checkBeforeAdding(in: app, settings: settings) == false)
        #expect(item.duplicateMessage?.contains("私有种子") == true)
        #expect(!item.canMergeTrackers)
        #expect(!item.duplicateAcknowledged)
    }

    @Test func sameBatchHashesAreDeduplicatedAfterConfirmation() async throws {
        let hash = String(repeating: "a", count: 40)
        let link = "magnet:?xt=urn:btih:" + hash
        let draft = NewTaskModel(inputText: link + "\n" + link + "&dn=sample")
        let app = AppModel(tasks: [])
        let temporaryDefaults = try TemporaryDefaults(prefix: "newtask.")
        defer { temporaryDefaults.clean() }
        let settings = SettingsModel(defaults: temporaryDefaults.defaults)
        #expect(await draft.checkBeforeAdding(in: app, settings: settings) == false)
        #expect(draft.links.first?.duplicateMessage == nil)
        draft.links.last?.duplicateAcknowledged = true
        #expect(await draft.checkBeforeAdding(in: app, settings: settings))
        draft.createTasks(in: app)
        #expect(app.tasks.count == 1)
    }


    @Test func publicDuplicateMergesTrackersThroughTheEngine() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configuration = TorrentEngineSettings(listenPort: 0, dht: false, lsd: false, portMapping: false)
        let engine = TorrentEngine(
            stateDirectory: root.appendingPathComponent("state"),
            binaryURL: Bundle.main.bundleURL.appending(path: "Contents/Helpers/mulee-torrentd"), settings: configuration
        )
        do {
            let torrent = root.appendingPathComponent("sample.torrent")
            let data = Data("d4:infod6:lengthi1e4:name6:sample12:piece lengthi16384e6:pieces20:".utf8)
                + Data(repeating: 0, count: 20) + Data("ee".utf8)
            try data.write(to: torrent)
            let link = ParsedLink.torrentFile(url: torrent, original: torrent.absoluteString)
            try await engine.start(options: EngineOptions(downloadDirectory: root))
            let id = try await engine.addQueued(link: link, directory: root)
            var task = DownloadTask(link: link, autoExtract: false)
            task.engineTaskID = id
            let app = AppModel(tasks: [task])
            app.bitTorrent = BitTorrentController(engine: engine, model: app, configuration: configuration)
            let tracker = "https://tracker.example.com/announce"
            let draft = NewTaskModel(inputText: "magnet:?xt=urn:btih:" + id + "&tr=" + tracker)
            let temporaryDefaults = try TemporaryDefaults(prefix: "newtask.")
            defer { temporaryDefaults.clean() }
            let settings = SettingsModel(defaults: temporaryDefaults.defaults)
            draft.refreshDuplicateWarnings(in: app)
            await draft.resolveDuplicateMetadata(in: app)
            let item = try #require(draft.links.first)
            #expect(item.duplicateMessage?.contains("公开种子") == true)
            #expect(item.canMergeTrackers)
            #expect(await draft.checkBeforeAdding(in: app, settings: settings) == false)
            #expect(!item.duplicateAcknowledged)
            await draft.mergeTrackers(for: item, in: app)
            #expect(item.duplicateAcknowledged)
            let trackers = try await engine.trackers(id)
            #expect(trackers.map(\.url).contains(tracker))
            #expect(await draft.checkBeforeAdding(in: app, settings: settings))
            draft.createTasks(in: app)
            #expect(app.tasks.count == 1)
            await engine.stop()
            try FileManager.default.removeItem(at: root)
        } catch {
            await engine.stop()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

}
