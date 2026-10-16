import CryptoKit
import AppKit
import Foundation
import MuleeCore
import SwiftUI
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

        #expect(configuration.blockedClients.isEmpty)
        settings.blockLeechingClients = true
        #expect(BitTorrentEngineConfiguration.configuration(from: settings).blockedClients == TorrentEngineSettings.defaultBlockedClients)
        settings.blockLeechingClients = false
        #expect(BitTorrentEngineConfiguration.configuration(from: settings).blockedClients.isEmpty)
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

    @Test("BT 新设置默认值、持久化和引擎映射")
    func managementSettings() throws {
        let temporaryDefaults = try TemporaryDefaults(prefix: "BitTorrentManagement.")
        defer { temporaryDefaults.clean() }
        let settings = SettingsModel(defaults: temporaryDefaults.defaults)
        #expect(settings.skipJunkFiles)
        #expect(settings.junkFilePatterns == TorrentEngineSettings.defaultJunkFilePatterns)
        #expect(settings.seedTimeLimitMinutes == 0 && settings.seedInactiveLimitMinutes == 0)
        #expect(settings.privateMinSeedMinutes == 0 && settings.ipBlocklistPath.isEmpty)
        settings.skipJunkFiles = false
        settings.junkFilePatterns = ["*.url"]
        settings.seedTimeLimitMinutes = 120
        settings.seedInactiveLimitMinutes = 30
        settings.privateMinSeedMinutes = 60
        settings.ipBlocklistPath = "/tmp/fixture-blocklist.dat"
        settings.seedingAction = .remove
        let restored = SettingsModel(defaults: temporaryDefaults.defaults)
        let configuration = BitTorrentEngineConfiguration.configuration(from: restored)
        #expect(!configuration.skipJunkFiles && configuration.junkFilePatterns == ["*.url"])
        #expect(configuration.seedTimeLimitMinutes == 120 && configuration.seedInactiveLimitMinutes == 30)
        #expect(configuration.privateMinSeedMinutes == 60 && configuration.ipBlocklistPath == settings.ipBlocklistPath)
        #expect(configuration.seedingAction == .remove)
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
            item.sequentialDownload = true

            draft.createTasks(in: app)
            for _ in 0..<300 {
                if app.tasks.first?.engineTaskID != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let task = try #require(app.tasks.first)
            let id = try #require(task.engineTaskID)
            let files = try await engine.files(id)
            #expect(files.map(\.priority) == [0, 4])
            let initialInfo = try await engine.taskInfo(id)
            #expect(initialInfo.sequentialDownload)
            #expect(initialInfo.firstLastPriority == false)
            let inspector = BitTorrentFilesModel()
            let observation = Task { await inspector.watch(engine: engine, id: id) }
            defer { observation.cancel() }
            for _ in 0..<300 {
                if inspector.info != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(inspector.info?.sequentialDownload == true)
            await inspector.setDownloadMode(sequentialDownload: false, firstLastPriority: true)
            #expect(inspector.info?.sequentialDownload == false)
            #expect(inspector.info?.firstLastPriority == true)
            let updatedInfo = try await engine.taskInfo(id)
            #expect(updatedInfo.sequentialDownload == false)
            #expect(updatedInfo.firstLastPriority)
            try captureInspectorExamples(info: updatedInfo)
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

    @Test("连接来源用中文展示；零来源与零次屏蔽隐藏")
    func diagnosticsPresentation() throws {
        let diagnostics = try #require(BitTorrentFilesModel.preview().diagnostics)
        let rows = BitTorrentFilesModel.sourceRows(diagnostics.peerSources)
        #expect(rows.map(\.title) == ["节点服务器（tracker）", "分布式网络", "节点交换", "局域网", "对方连入"])
        #expect(rows.map(\.count) == [4, 6, 3, 1, 2])
        #expect(BitTorrentFilesModel.trackerSummary(diagnostics) == "可用 3 个，失败 1 个")
        let zeroSources = try JSONDecoder().decode(TorrentPeerSources.self, from: Data("""
            { "tracker": 0, "dht": 0, "pex": 0, "lsd": 0, "incoming": 0 }
            """.utf8))
        #expect(BitTorrentFilesModel.sourceRows(zeroSources).isEmpty)
        #expect(BitTorrentFilesModel.blockedClientsMessage(0) == nil)
        #expect(BitTorrentFilesModel.blockedClientsMessage(5) == "已屏蔽客户端 5 次")
        #expect(BitTorrentFilesModel.trackerError(nil) == nil)
        #expect(BitTorrentFilesModel.trackerError(" \n") == nil)
    }

    @Test("服务器错误不泄露原始地址，换成可读说明", arguments: [
        ("Connection timed out", "节点服务器响应太慢，稍后会重试。"),
        ("Host not found", "暂时找不到节点服务器的地址，稍后会重试。"),
        ("certificate verify failed", "无法确认节点服务器的安全连接，稍后会重试。"),
        ("HTTP 403", "节点服务器未允许此任务连接，请检查种子是否仍可用。"),
        ("Torrent not registered", "节点服务器未允许此任务连接，请检查种子是否仍可用。"),
        ("HTTP 429", "节点服务器正忙，稍后会重试。"),
        ("unknown https://example.com/private-key", "暂时无法连接节点服务器，稍后会重试。")
    ])
    func trackerErrors(error: String, expected: String) {
        #expect(BitTorrentFilesModel.trackerError(error) == expected)
    }

    @Test("磁盘积压、正常和尚未采样使用不同文案")
    func diskPressure() {
        #expect(BitTorrentFilesModel.diskMessage(true) == "硬盘写入跟不上下载速度")
        #expect(BitTorrentFilesModel.diskMessage(false) == "硬盘写入正常")
        #expect(BitTorrentFilesModel.diskMessage(nil) == "正在检测硬盘写入情况")
    }

    @Test("单文件详情进度采用同一采样，切换任务不会沿用上一个任务")
    func consistentSingleFileProgress() throws {
        var task = try #require(MockData.tasks.first { $0.kind == .bittorrent })
        task.status = .downloading
        task.engineTaskID = "same-sample"
        task.totalBytes = 100
        task.receivedBytes = 16
        let file = TorrentFileEntry(index: 0, path: "video.mp4", size: 100, done: 12)
        let model = try BitTorrentFilesModel.preview(id: "same-sample", files: [file])
        let presentation = TaskPresentation(task: model.displayTask(task))
        #expect(presentation.progress == BitTorrentFilesModel.progress(for: file))
        #expect(presentation.progressText.hasPrefix("12%"))
        task.engineTaskID = "another-task"
        #expect(model.displayTask(task).receivedBytes == 16)
    }

    @Test("多文件按所选字节汇总，忽略未选文件并限制异常进度范围")
    func weightedFileProgress() throws {
        var task = try #require(MockData.tasks.first { $0.kind == .bittorrent })
        task.status = .downloading
        task.engineTaskID = "weighted"
        let files = [
            TorrentFileEntry(index: 0, path: "a", size: 100, done: 150),
            TorrentFileEntry(index: 1, path: "b", size: 300, done: 100),
            TorrentFileEntry(index: 2, path: "skip", size: 1000, done: 900, priority: 0),
            TorrentFileEntry(index: 3, path: "empty", size: 0),
            TorrentFileEntry(index: 4, path: "negative", size: 100, done: -10)
        ]
        let model = try BitTorrentFilesModel.preview(id: "weighted", files: files)
        let display = model.displayTask(task)
        #expect(display.totalBytes == 500)
        #expect(display.receivedBytes == 200)
        #expect(TaskPresentation(task: display).progress == 0.4)
        #expect(BitTorrentFilesModel.progress(for: files[0]) == 1)
        #expect(BitTorrentFilesModel.progress(for: files[3]) == 1)
        #expect(BitTorrentFilesModel.progress(for: files[4]) == 0)
    }

    private func captureInspectorExamples(info: TorrentTaskInfo) throws {
        let output = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "build")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let app = AppModel(tasks: [])
        let temporaryDefaults = try TemporaryDefaults(prefix: "BitTorrentScreenshots.")
        defer { temporaryDefaults.clean() }
        let settings = SettingsModel(defaults: temporaryDefaults.defaults)
        var task = try #require(MockData.tasks.first { $0.kind == .bittorrent })
        task.status = .downloading
        let model = try BitTorrentFilesModel.preview(info: info, id: task.engineTaskID)
        let presentation = TaskPresentation(task: model.displayTask(task))
        for scheme in [ColorScheme.light, .dark] {
            let content = VStack(alignment: .leading, spacing: 12) {
                Text("BT 任务详情").font(.headline)
                ProgressView(value: presentation.progress)
                Text(presentation.progressText).font(.caption)
                BitTorrentInspectorView(task: task, model: model, showsConnections: true)
            }
            .padding(18)
            .frame(width: 300)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(app)
            .environment(\.colorScheme, scheme)
            try capture(content, scheme: scheme, to: output.appending(path: "bt-inspector-\(scheme == .dark ? "dark" : "light").png"))
            if scheme == .dark {
                try capture(content.environment(\.dynamicTypeSize, .accessibility3), scheme: scheme,
                            to: output.appending(path: "bt-inspector-large-text.png"))
            }
            let previewLink = try #require(NewTaskPreviewData.links.first)
            let draft = NewTaskModel(
                inputText: previewLink.original, saveDirectory: URL(filePath: "/tmp/Mulee preview"),
                parser: { _ in [previewLink] }, metadataProvider: ExampleTorrentMetadataProvider()
            )
            let newTask = NewTaskSheet(draft: draft)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(app)
                .environment(settings)
                .environment(\.colorScheme, scheme)
            try capture(newTask, scheme: scheme, to: output.appending(path: "bt-new-task-\(scheme == .dark ? "dark" : "light").png"))
        }
    }

    private func capture(_ view: some View, scheme: ColorScheme, to url: URL) throws {
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let size = hosting.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url)
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
