import Foundation
import MuleeCore
import Testing
@testable import Mulee

@Suite @MainActor struct NewTaskVideoPlaylistTests {
    private func entries() throws -> [YtDlpPlaylistEntry] {
        let source = try #require(URL(string: "https://www.youtube.com/playlist?list=ExampleList"))
        let json = Data(#"""
        {"title":"../示例:列表","entries":[
            {"id":"Example0001","ie_key":"Youtube","title":"示例一"},
            {"id":"Example0002","ie_key":"Youtube","title":"示例二"}
        ]}
        """#.utf8)
        return try YtDlpPlaylist.parse(json, source: source)
    }

    @Test(arguments: [
        "https://www.youtube.com/watch?v=Example0002&list=ExampleList",
        "https://youtu.be/Example0002?list=ExampleList",
        "https://music.youtube.com/watch?v=Example0002&list=ExampleList"
    ])
    func videoInPlaylistSelectsOnlyCurrentVideo(_ text: String) async throws {
        let draft = NewTaskModel(inputText: text)
        let item = try #require(draft.links.first)
        let parts = try entries()

        await item.loadVideoParts { _ in parts }

        #expect(item.selectedVideoParts == [parts[1].id])
        #expect(draft.downloadLinks == [parts[1].link])
        #expect(draft.canStartDownload)
        item.selectedVideoParts = []
        #expect(!draft.canStartDownload)
        #expect(draft.downloadLinks.isEmpty)
    }

    @Test func purePlaylistNeedsSelectionAndNeverProbesWholeList() async throws {
        let draft = NewTaskModel(inputText: "https://www.youtube.com/playlist?list=ExampleList")
        let item = try #require(draft.links.first)
        let parts = try entries()
        #expect(!draft.canStartDownload)
        var probes = 0
        await item.loadVideoFormats { _, _ -> YtDlpVideoMetadata in
            probes += 1
            return YtDlpVideoMetadata(formats: [])
        }
        #expect(probes == 0)

        await item.loadVideoParts { _ in parts }

        #expect(item.selectedVideoParts.isEmpty)
        #expect(!draft.canStartDownload)
        let app = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        draft.createTasks(in: app)
        #expect(app.tasks.isEmpty)
        item.selectedVideoParts = [parts[1].id]
        await item.loadVideoFormats { url, _ -> YtDlpVideoMetadata in
            probes += 1
            #expect(url == parts[1].url)
            return YtDlpVideoMetadata(formats: [], videoIdentity: "Youtube:Example0002")
        }
        #expect(probes == 1)
        #expect(item.videoMetadata?.videoIdentity == "Youtube:Example0002")
        #expect(draft.canStartDownload)
        draft.createTasks(in: app)
        #expect(app.tasks.count == 1)
        #expect(app.tasks.first?.sourceLink == parts[1].url.absoluteString)
        #expect(app.tasks.first?.videoIdentity == "Youtube:Example0002")
    }

    @Test func singleEntryPurePlaylistStillRequiresExplicitSelection() async throws {
        let draft = NewTaskModel(inputText: "https://www.youtube.com/playlist?list=ExampleList")
        let item = try #require(draft.links.first)
        let parts = Array(try entries().prefix(1))

        await item.loadVideoParts { _ in parts }

        #expect(!draft.canStartDownload)
        item.selectedVideoParts = [parts[0].id]
        #expect(draft.canStartDownload)
        item.selectedVideoParts = [URL(filePath: "/tmp/unrelated-entry")]
        #expect(!draft.canStartDownload)
    }

    @Test func playlistFailureDoesNotCreateWholeListTask() async throws {
        let draft = NewTaskModel(inputText: "https://www.youtube.com/playlist?list=ExampleList")
        let item = try #require(draft.links.first)

        await item.loadVideoParts { _ in throw EngineError.unsupportedLink }

        #expect(item.videoPartsError != nil)
        #expect(!draft.canStartDownload)
        #expect(draft.downloadLinks.isEmpty)
        let app = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        draft.createTasks(in: app)
        #expect(app.tasks.isEmpty)
    }

    @Test(arguments: [true, false])
    func multipleSelectionsUseSafeOptionalSubfolder(_ enabled: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let draft = NewTaskModel(inputText: "https://www.youtube.com/playlist?list=ExampleList", saveDirectory: root)
        let item = try #require(draft.links.first)
        let parts = try entries()
        await item.loadVideoParts { _ in parts }
        #expect(item.playlistSubfolder)
        item.selectedVideoParts = Set(parts.map(\.id))
        #expect(item.showsPlaylistSubfolder)
        item.playlistSubfolder = enabled
        let app = AppModel(tasks: [], preventsSleepWhileDownloading: false)

        draft.createTasks(in: app)

        #expect(app.tasks.count == 2)
        #expect(app.tasks.map(\.name) == ["#1 示例一", "#2 示例二"])
        #expect(app.tasks.map(\.videoIdentity) == ["Youtube:Example0001", "Youtube:Example0002"])
        let expected = enabled ? root.appendingPathComponent("示例 列表", isDirectory: true) : root
        #expect(app.tasks.allSatisfy { $0.writeDirectories == [expected] })
        #expect(app.tasks.allSatisfy { !$0.sourceLink.contains("list=") })
    }

    @Test func identityDuplicateIsAdvisoryAndIgnoresDeletedTasks() async throws {
        let text = "https://www.youtube.com/watch?v=Example0001"
        let link = try #require(LinkParser.parse(text).first)
        var task = DownloadTask(link: link, autoExtract: false)
        task.videoIdentity = "Youtube:Example0001"
        let app = AppModel(tasks: [task], preventsSleepWhileDownloading: false)
        let draft = NewTaskModel(inputText: text)
        let item = try #require(draft.links.first)
        await item.loadVideoFormats { _, _ -> YtDlpVideoMetadata in
            YtDlpVideoMetadata(formats: [], videoIdentity: "Youtube:Example0001")
        }

        draft.refreshDuplicateWarnings(in: app)

        #expect(item.existingDownloadID == task.id)
        #expect(item.existingDownloadMessage == "这个视频已在任务列表里")
        #expect(item.duplicateMessage == nil)
        #expect(draft.canStartDownload)
        let temporary = try TemporaryDefaults(prefix: "video-duplicate.")
        defer { temporary.clean() }
        #expect(await draft.checkBeforeAdding(in: app, settings: SettingsModel(defaults: temporary.defaults)))
        draft.createTasks(in: app)
        #expect(app.tasks.count == 2)
        #expect(app.tasks.first?.videoIdentity == task.videoIdentity)
        var unrelated = task
        unrelated.videoIdentity = "OtherExtractor:Example0001"
        item.refreshExistingDownload(in: [unrelated])
        #expect(item.existingDownloadID == nil)
        task.deletedAt = .now
        item.refreshExistingDownload(in: [task])
        #expect(item.existingDownloadMessage == nil)
    }

    @Test func coordinatorKeepsIdentityThroughEngineSnapshots() async throws {
        let app = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        let video = FakeEngine(kind: .video)
        let coordinator = DownloadCoordinator(model: app, engines: [video])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let part = try #require(entries().first)
        await coordinator.start(options: EngineOptions(downloadDirectory: root))

        await coordinator.add(
            links: [part.link], autoExtract: false, directory: root,
            videoEntries: [part.link: part], videoIdentities: [part.link: "Youtube:Example0001"]
        )

        #expect(app.tasks.first?.videoIdentity == "Youtube:Example0001")
        #expect(app.tasks.first?.name == "#1 示例一")
        #expect(await video.addedLinks == [part.link])
        await video.setSnapshots([
            EngineTaskSnapshot(
                engineTaskID: "task-1", name: "#1 示例一", totalBytes: 100,
                receivedBytes: 50, downloadRate: 10, uploadRate: 0, status: .downloading,
                connections: 1, savePath: nil, sourceURL: part.url, errorMessage: nil
            )
        ])
        await coordinator.poll()
        #expect(app.tasks.first?.videoIdentity == "Youtube:Example0001")
        await coordinator.stop()
    }

    @Test func httpDuplicatesIgnoreFragmentsKeepQueriesAndRequireExistingFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sample.zip")
        try Data("example".utf8).write(to: file)
        let first = try #require(LinkParser.parse("https://example.org/sample.zip?version=1#old").first)
        let item = NewTaskLinkModel(link: try #require(LinkParser.parse("https://example.org/sample.zip?version=1#new").first))
        var task = DownloadTask(link: first, autoExtract: false)
        task.savePath = file

        item.refreshExistingDownload(in: [task])

        #expect(item.existingDownloadMessage == "这个链接下载过")
        #expect(item.existingDownloadFile == file)
        #expect(item.canStart)
        let app = AppModel(tasks: [task], preventsSleepWhileDownloading: false)
        let draft = NewTaskModel(inputText: item.link.original, saveDirectory: root)
        let temporary = try TemporaryDefaults(prefix: "http-duplicate.")
        defer { temporary.clean() }
        draft.refreshDuplicateWarnings(in: app)
        #expect(await draft.checkBeforeAdding(in: app, settings: SettingsModel(defaults: temporary.defaults)))
        draft.createTasks(in: app)
        #expect(app.tasks.count == 2)
        try FileManager.default.removeItem(at: file)
        item.refreshExistingDownload(in: [task])
        #expect(item.existingDownloadID == task.id)
        #expect(item.existingDownloadFile == nil)
        task.sourceLink = "https://example.org/sample.zip?version=2"
        item.refreshExistingDownload(in: [task])
        #expect(item.existingDownloadMessage == nil)
        task.sourceLink = first.original
        task.deletedAt = .now
        item.refreshExistingDownload(in: [task])
        #expect(item.existingDownloadMessage == nil)
    }

    @Test func videoIdentityRoundTripsAndOldHistoryStillDecodes() throws {
        let link = try #require(LinkParser.parse("https://www.youtube.com/watch?v=Example0001").first)
        var task = DownloadTask(link: link, autoExtract: false)
        let oldData = try JSONEncoder().encode(task)
        #expect(try JSONDecoder().decode(DownloadTask.self, from: oldData).videoIdentity == nil)
        task.videoIdentity = "Youtube:Example0001"

        let decoded = try JSONDecoder().decode(DownloadTask.self, from: JSONEncoder().encode(task))

        #expect(decoded.videoIdentity == task.videoIdentity)
    }
}
