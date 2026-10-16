import CryptoKit
import Foundation
import MuleeCore
import Testing
@testable import Mulee

@Suite @MainActor struct BitTorrentTests {
    @Test("设置映射保留默认发现与加密，端口、策略、限速和目录使用用户值")
    func configuration() throws {
        let temporaryDefaults = try TemporaryDefaults(prefix: "BitTorrentTests.")
        defer { temporaryDefaults.clean() }
        let defaults = temporaryDefaults.defaults
        let settings = SettingsModel(defaults: defaults)
        settings.btPort = 12345
        settings.portMapping = false
        settings.seedingAction = .stop
        settings.privateIgnoresRatio = false
        settings.downloadLimit = 5
        settings.uploadLimit = 0.5
        settings.saveDirectory = "/tmp/Mulee fixture"

        let configuration = BitTorrentEngineConfiguration.configuration(from: settings)
        let options = EngineOptionsMapper.options(from: settings)

        #expect(configuration.listenPort == 12345)
        #expect(!configuration.portMapping)
        #expect(configuration.dht && configuration.lsd)
        #expect(configuration.encryption == .prefer)
        #expect(configuration.seedingAction == .stop)
        #expect(!configuration.exemptPrivateTorrents)
        #expect(options.downloadLimit == 5_000_000)
        #expect(options.uploadLimit == 500_000)
        #expect(options.downloadDirectory.path == settings.saveDirectory)
        settings.seedingAction = .throttle
        #expect(BitTorrentEngineConfiguration.configuration(from: settings).seedingAction == .slowDown)
    }

    @Test("端口推导三态、连接历史与入站优先")
    func reachability() {
        let start = Date(timeIntervalSince1970: 1000)
        var state = BitTorrentPortReachability(startedAt: start)
        #expect(state.observe(incoming: false, now: start.addingTimeInterval(900)) == nil)
        state.observePeers(true)
        state.observePeers(false)
        #expect(state.observe(incoming: false, now: start.addingTimeInterval(600)) == nil)
        #expect(state.observe(incoming: false, now: start.addingTimeInterval(601)) == false)
        #expect(state.observe(incoming: true, now: start.addingTimeInterval(602)) == true)
        #expect(state.observe(incoming: false, now: start.addingTimeInterval(603)) == true)
        var fresh = BitTorrentPortReachability(startedAt: start)
        #expect(fresh.observe(incoming: true, now: start) == true)
    }

    @Test("临时种子展示真实名称、大小、文件数，勾选转为 0/4")
    func localTorrent() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "fixture.torrent")
        try torrentData().write(to: url)

        let draft = NewTaskModel()
        #expect(draft.appendTorrentFiles([url]))
        let item = try #require(draft.links.first)
        #expect(item.name == "Mulee fixture")
        #expect(item.totalSize == 32768)
        #expect(item.files?.map(\.name) == ["Mulee fixture/a.txt", "Mulee fixture/b.txt"])
        #expect(item.detail.contains("2"))
        item.files?[0].isSelected = false
        #expect(item.filePriorities == [0, 4])
        #expect(draft.filePriorities[item.link] == [0, 4])
        let remaining = try #require(item.files?.last)
        #expect(!item.canDeselect(remaining))
        item.files?[1].isSelected = false
        #expect(!draft.canStartDownload)
    }

    @Test("正式磁力和远程种子不展示示例元数据，损坏本地种子不能提交")
    func unavailableMetadata() throws {
        let magnet = NewTaskModel(inputText: NewTaskPreviewData.inputText)
        #expect(magnet.links.first?.files == nil)
        let remote = NewTaskModel(inputText: "https://example.com/mulee.torrent")
        #expect(remote.links.first?.files == nil)
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "broken.torrent")
        try Data("broken".utf8).write(to: url)
        let draft = NewTaskModel(inputText: url.absoluteString)
        #expect(draft.links.first?.metadataError != nil)
        #expect(!draft.canStartDownload)
        #expect(!draft.appendTorrentFiles([root.appending(path: "ordinary.txt")]))
    }

    @Test("详情至少保留一个文件，允许重新勾选")
    func keepOneFile() {
        let files = [
            TorrentFileEntry(index: 0, path: "a", size: 10, priority: 0),
            TorrentFileEntry(index: 1, path: "b", size: 10)
        ]
        #expect(BitTorrentFilesModel.priorities(for: files, index: 1, selected: false) == nil)
        #expect(BitTorrentFilesModel.priorities(for: files, index: 0, selected: true) == [4, 4])
        #expect(BitTorrentFilesModel.priorities(for: files, index: 9, selected: true) == nil)
    }

    @Test("做种文案遵循设置，并且可以暂停")
    func seedingText() throws {
        var task = try #require(MockData.tasks.first { $0.kind == .bittorrent })
        task.status = .seeding
        let stop = TaskPresentation(task: task, seedingAction: .stop)
        let throttle = TaskPresentation(task: task, seedingAction: .throttle)
        #expect(stop.progressText.contains("到 1:1 后停止"))
        #expect(throttle.progressText.contains("到 1:1 后降速"))
        #expect(stop.canPauseOrResume)
        #expect(stop.pauseTitle == "暂停")
    }

    @Test("filePriorities 从草稿经 AppModel 和协调器传到真实 BT 引擎")
    func prioritySubmission() async throws {
        let root = try fixtureDirectory()
        let binary = Bundle.main.bundleURL.appending(path: "Contents/Helpers/mulee-torrentd")
        let engine = TorrentEngine(
            stateDirectory: root.appending(path: "state"), binaryURL: binary,
            settings: TorrentEngineSettings(listenPort: 0, dht: false, lsd: false, portMapping: false)
        )
        let app = AppModel(tasks: [])
        let coordinator = DownloadCoordinator(model: app, engines: [engine])
        do {
            let url = root.appending(path: "fixture.torrent")
            try torrentData().write(to: url)
            await coordinator.start(options: EngineOptions(downloadDirectory: root))
            #expect(app.engineStates[.bittorrent] == .running)
            let draft = NewTaskModel(inputText: url.absoluteString, saveDirectory: root, autoExtract: false)
            let item = try #require(draft.links.first)
            item.files?[0].isSelected = false

            draft.createTasks(in: app)
            for _ in 0..<300 {
                if app.tasks.first?.engineTaskID != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let task = try #require(app.tasks.first)
            let id = try #require(task.engineTaskID)
            let files = try await engine.files(id)
            #expect(files.map(\.priority) == [0, 4])
            #expect(!task.postDownload.autoExtract)
            try await engine.setFilePriorities(id, [4, 0])
            #expect(try await engine.files(id).map(\.priority) == [4, 0])
            await coordinator.remove(task.id, deleteFiles: true)
            #expect(app.tasks.isEmpty)
            #expect(try await engine.snapshots().isEmpty)
            await coordinator.stop()
            try FileManager.default.removeItem(at: root)
        } catch {
            await coordinator.stop()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private func fixtureDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "Mulee-BitTorrent-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func torrentData() -> Data {
        let payload = Data(repeating: 0, count: 16384)
        let piece = Data(Insecure.SHA1.hash(data: payload))
        return Data("d4:infod5:filesld6:lengthi16384e4:pathl5:a.txteed6:lengthi16384e4:pathl5:b.txteee4:name13:Mulee fixture12:piece lengthi16384e6:pieces40:".utf8)
            + piece + piece + Data("ee".utf8)
    }
}
