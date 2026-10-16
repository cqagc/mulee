import Foundation
import MuleeCore
import Testing
@testable import Mulee

@MainActor
@Suite struct BitTorrentUITests {
    @Test func trackerValidation() {
        #expect(BitTorrentManagementModel.trackerValidation([]) == nil)
        #expect(BitTorrentManagementModel.trackerValidation([
            "https://tracker.invalid/announce", "udp://tracker.invalid:6969/announce"
        ]) == nil)
        for urls in [[""], ["file:///fixture"], ["https:///announce"], ["https://tracker.invalid/a b"],
                     ["https://tracker.invalid", "https://tracker.invalid"],
                     (0..<51).map { "https://tracker\($0).invalid/announce" }] {
            #expect(BitTorrentManagementModel.trackerValidation(urls) != nil)
        }
    }

    @Test func renameValidation() {
        for name in ["", " \n", "a/b", ".", "..", "a\0b"] {
            #expect(BitTorrentManagementModel.renameValidation(name) != nil)
            #expect(BitTorrentManagementModel.renamedPath("folder/file.bin", name: name) == nil)
        }
        #expect(BitTorrentManagementModel.renamedPath("folder/file.bin", name: "新文件.bin") == "folder/新文件.bin")
        #expect(BitTorrentManagementModel.renamedPath("folder", name: "新目录") == "新目录")
    }

    @Test func peerFormatting() throws {
        let peer = try JSONDecoder().decode(TorrentPeer.self, from: Data("""
            {
                "address": "2001:db8::1", "port": 6881, "client": "Example client", "progress": 0.25,
                "downloadRate": 1024, "uploadRate": 512, "sources": ["tracker", "pex"], "connection": "utp"
            }
            """.utf8))
        #expect(BitTorrentManagementModel.peerAddress(peer) == "[2001:db8::1]:6881")
        #expect(BitTorrentManagementModel.peerProgress(peer) == 0.25.formatted(.percent.precision(.fractionLength(0))))
        #expect(BitTorrentManagementModel.peerSpeed(-1) == 0.formatted(.byteCount(style: .file)) + "/s")
        #expect(BitTorrentManagementModel.peerSources(peer.sources) == "节点服务器、节点交换")
        #expect(BitTorrentManagementModel.peerConnection(peer.connection) == "UDP（uTP）")
    }

    @Test func trackerStatus() throws {
        let tracker = try JSONDecoder().decode(TorrentTrackerStatus.self, from: Data("""
            {
                "url": "https://tracker.invalid/announce", "tier": 0, "status": "disabled",
                "lastResult": "timeout", "peers": 2, "disabledUntil": 10000, "subscription": true
            }
            """.utf8))
        #expect(BitTorrentManagementModel.trackerState(tracker) == "已暂停 24 小时（连续失败）")
        #expect(BitTorrentManagementModel.trackerResult(tracker) == "节点服务器响应太慢，稍后会重试。")
    }

    @Test func watchSettingsPersistence() throws {
        let storage = try TemporaryDefaults(prefix: "BitTorrentUI.")
        defer { storage.clean() }
        let settings = SettingsModel(defaults: storage.defaults)
        #expect(settings.watchFolders.isEmpty)
        #expect(!settings.watchAutoStart)
        settings.watchFolders = ["/tmp/fixture-watch"]
        settings.watchAutoStart = true
        let restored = SettingsModel(defaults: storage.defaults)
        #expect(restored.watchFolders == ["/tmp/fixture-watch"])
        #expect(restored.watchAutoStart)
        #expect(SettingsModel.Key.watchFolders == "bt.watchFolders")
        #expect(SettingsModel.Key.watchAutoStart == "bt.watchAutoStart")
    }

    @Test func realTorrentRenameAndMoveRefreshBookmarkedLocation() async throws {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appending(path: "Mulee-bt-ui-" + UUID().uuidString, directoryHint: .isDirectory)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: folder) }
        let source = folder.appending(path: "payload.bin")
        try Data(repeating: 7, count: 32_768).write(to: source)
        let configuration = TorrentEngineSettings(listenPort: 0, dht: false, lsd: false, portMapping: false)
        let engine = TorrentEngine(
            stateDirectory: folder.appending(path: "state"),
            binaryURL: Bundle.main.bundleURL.appending(path: "Contents/Helpers/mulee-torrentd"), settings: configuration
        )
        let app = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        let controller = BitTorrentController(engine: engine, model: app, configuration: configuration)
        do {
            try await engine.start(options: EngineOptions(downloadDirectory: folder))
            let torrent = folder.appending(path: "fixture.torrent")
            _ = try await engine.createTorrent(from: source, to: torrent)
            let draft = NewTaskModel(inputText: torrent.absoluteString)
            let link = try #require(draft.downloadLinks.first)
            let id = try await engine.add(link: link, directory: folder)
            var task = DownloadTask(link: link, autoExtract: false)
            task.engineTaskID = id
            task.savePath = source
            FileTracker.capture(&task)
            #expect(task.fileBookmark != nil)
            app.tasks = [task]
            try await engine.renameFile(id, path: "payload.bin", to: "renamed.bin")
            await controller.refreshTaskLocation(id)
            #expect(app.tasks.first?.savePath?.lastPathComponent == "renamed.bin")
            let destination = folder.appending(path: "moved", directoryHint: .isDirectory)
            try manager.createDirectory(at: destination, withIntermediateDirectories: true)
            try await engine.moveStorage(id, to: destination)
            await controller.refreshTaskLocation(id)
            #expect(app.tasks.first?.savePath?.resolvingSymlinksInPath().path == destination.appending(path: "renamed.bin").resolvingSymlinksInPath().path)
            #expect(manager.fileExists(atPath: destination.appending(path: "renamed.bin").path))
            await engine.stop()
        } catch {
            await engine.stop()
            throw error
        }
    }
}
