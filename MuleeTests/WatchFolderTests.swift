import Foundation
import MuleeCore
import Testing
@testable import Mulee

@MainActor
@Suite struct WatchFolderTests {
    private let magnet = "magnet:?xt=urn:btih:0123456789012345678901234567890123456789"

    @Test func waitsForStableSizeAndArchivesWithNumbering() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "fixture.magnet")
        try Data(magnet.prefix(10).utf8).write(to: file)
        let watcher = TorrentWatchFolderService()
        let start = Date(timeIntervalSince1970: 1000)
        var calls = 0
        let handler: TorrentWatchFolderService.Handler = { _, text, autoStart in
            #expect(text == magnet)
            #expect(autoStart)
            calls += 1
            return true
        }
        await watcher.scan(folders: [folder], autoStart: true, now: start, handler: handler)
        #expect(calls == 0)
        try Data(magnet.utf8).write(to: file)
        await watcher.scan(folders: [folder], autoStart: true, now: start.addingTimeInterval(0.5), handler: handler)
        await watcher.scan(folders: [folder], autoStart: true, now: start.addingTimeInterval(1.4), handler: handler)
        #expect(calls == 0)
        await watcher.scan(folders: [folder], autoStart: true, now: start.addingTimeInterval(1.5), handler: handler)
        #expect(calls == 1)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let archive = folder.appending(path: ".mulee-added")
        #expect(try String(contentsOf: archive.appending(path: "fixture.magnet"), encoding: .utf8) == magnet)
        try Data(magnet.utf8).write(to: file)
        _ = try TorrentWatchFolderService.archive(file)
        #expect(FileManager.default.fileExists(atPath: archive.appending(path: "fixture (1).magnet").path))
    }

    @Test func confirmationCancellationAndFailuresKeepOriginal() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "confirm.magnet")
        try Data(magnet.utf8).write(to: file)
        let watcher = TorrentWatchFolderService()
        let start = Date(timeIntervalSince1970: 1000)
        var confirmations = 0
        let cancel: TorrentWatchFolderService.Handler = { _, _, autoStart in
            #expect(!autoStart)
            confirmations += 1
            return false
        }
        await watcher.scan(folders: [folder], autoStart: false, now: start, handler: cancel)
        await watcher.scan(folders: [folder], autoStart: false, now: start.addingTimeInterval(1), handler: cancel)
        await watcher.scan(folders: [folder], autoStart: false, now: start.addingTimeInterval(2), handler: cancel)
        #expect(confirmations == 1)
        #expect(FileManager.default.fileExists(atPath: file.path))
        watcher.retry()
        let failure: TorrentWatchFolderService.Handler = { _, _, _ in throw CocoaError(.fileWriteNoPermission) }
        await watcher.scan(folders: [folder], autoStart: false, now: start.addingTimeInterval(3), handler: failure)
        await watcher.scan(folders: [folder], autoStart: false, now: start.addingTimeInterval(4), handler: failure)
        #expect(watcher.lastError != nil)
        #expect(FileManager.default.fileExists(atPath: file.path))
        watcher.retry()
        var confirmed = false
        let accept: TorrentWatchFolderService.Handler = { _, _, autoStart in
            #expect(!autoStart)
            confirmed = true
            return true
        }
        await watcher.scan(folders: [folder], autoStart: false, now: start.addingTimeInterval(5), handler: accept)
        await watcher.scan(folders: [folder], autoStart: false, now: start.addingTimeInterval(6), handler: accept)
        #expect(confirmed)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func incompleteFileRetriesUntilThreeStableParsingFailures() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "partial.magnet")
        try Data("magnet:?xt=".utf8).write(to: file)
        let watcher = TorrentWatchFolderService()
        let start = Date(timeIntervalSince1970: 1000)
        let handler: TorrentWatchFolderService.Handler = { _, _, _ in true }
        await watcher.scan(folders: [folder], autoStart: true, now: start, handler: handler)
        for second in 1...2 {
            await watcher.scan(folders: [folder], autoStart: true, now: start.addingTimeInterval(Double(second)), handler: handler)
            #expect(watcher.lastError == nil)
        }
        await watcher.scan(folders: [folder], autoStart: true, now: start.addingTimeInterval(3), handler: handler)
        #expect(watcher.lastError != nil)
        #expect(FileManager.default.fileExists(atPath: file.path))
        try Data(magnet.utf8).write(to: file)
        await watcher.scan(folders: [folder], autoStart: true, now: start.addingTimeInterval(4), handler: handler)
        await watcher.scan(folders: [folder], autoStart: true, now: start.addingTimeInterval(5), handler: handler)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func periodicScanFindsChangesWithoutDirectoryEvents() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let watcher = TorrentWatchFolderService()
        let start = Date(timeIntervalSince1970: 1000)
        var calls = 0
        let handler: TorrentWatchFolderService.Handler = { _, _, _ in
            calls += 1
            return true
        }
        await watcher.scan(folders: [folder], autoStart: true, now: start, handler: handler)
        let file = folder.appending(path: "missed-event.magnet")
        try Data(magnet.utf8).write(to: file)
        #expect(!watcher.shouldScan(at: start.addingTimeInterval(29)))
        #expect(watcher.shouldScan(at: start.addingTimeInterval(30)))
        await watcher.scan(folders: [folder], autoStart: true, now: start.addingTimeInterval(30), handler: handler)
        #expect(watcher.shouldScan(at: start.addingTimeInterval(31)))
        await watcher.scan(folders: [folder], autoStart: true, now: start.addingTimeInterval(31), handler: handler)
        #expect(calls == 1)
        #expect(!watcher.shouldScan(at: start.addingTimeInterval(60)))
    }

    @Test func fileChangesResetStableParsingFailureCount() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "growing.magnet")
        try Data("magnet:?".utf8).write(to: file)
        let watcher = TorrentWatchFolderService()
        let start = Date(timeIntervalSince1970: 1000)
        let handler: TorrentWatchFolderService.Handler = { _, _, _ in true }
        for second in 0...2 {
            await watcher.scan(folders: [folder], autoStart: true, now: start.addingTimeInterval(Double(second)), handler: handler)
        }
        #expect(watcher.lastError == nil)
        #expect(watcher.shouldScan(at: start.addingTimeInterval(3)))
        try Data("magnet:?xt=".utf8).write(to: file)
        for second in 3...5 {
            await watcher.scan(folders: [folder], autoStart: true, now: start.addingTimeInterval(Double(second)), handler: handler)
        }
        #expect(watcher.lastError == nil)
        try Data(magnet.utf8).write(to: file)
        await watcher.scan(folders: [folder], autoStart: true, now: start.addingTimeInterval(6), handler: handler)
        await watcher.scan(folders: [folder], autoStart: true, now: start.addingTimeInterval(7), handler: handler)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func parsesMagnetTextAndRejectsOtherContent() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "fixture.magnet")
        try Data((" \n" + magnet + "\n").utf8).write(to: file)
        #expect(try TorrentWatchFolderService.inputText(for: file) == magnet)
        for text in ["https://example.invalid/file", magnet + "\n" + magnet, "not a magnet"] {
            try Data(text.utf8).write(to: file)
            #expect(throws: (any Error).self) { try TorrentWatchFolderService.inputText(for: file) }
        }
    }

    @Test func scansExistingTorrentAndIgnoresArchive() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "fixture.torrent")
        try Data("d4:infod6:lengthi1e4:name7:fixture12:piece lengthi16384e6:pieces20:00000000000000000000ee".utf8).write(to: file)
        let watcher = TorrentWatchFolderService()
        let start = Date(timeIntervalSince1970: 1000)
        var calls = 0
        let handler: TorrentWatchFolderService.Handler = { source, text, _ in
            #expect(source.resolvingSymlinksInPath().path == file.resolvingSymlinksInPath().path)
            #expect(text == source.absoluteString)
            calls += 1
            return true
        }
        await watcher.scan(folders: [folder], autoStart: true, now: start, handler: handler)
        await watcher.scan(folders: [folder], autoStart: true, now: start.addingTimeInterval(1), handler: handler)
        await watcher.scan(folders: [folder], autoStart: true, now: start.addingTimeInterval(2), handler: handler)
        #expect(calls == 1)
    }

    @Test func doesNotArchiveFileReplacedDuringConfirmation() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "fixture.magnet")
        try Data(magnet.utf8).write(to: file)
        let watcher = TorrentWatchFolderService()
        let start = Date(timeIntervalSince1970: 1000)
        let handler: TorrentWatchFolderService.Handler = { _, _, _ in
            try Data((magnet + "&dn=updated").utf8).write(to: file)
            return true
        }
        await watcher.scan(folders: [folder], autoStart: false, now: start, handler: handler)
        await watcher.scan(folders: [folder], autoStart: false, now: start.addingTimeInterval(1), handler: handler)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func directoryEventsProcessNewFilesAndStopWithService() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let storage = try TemporaryDefaults(prefix: "WatchFolderEvents.")
        defer { storage.clean() }
        let settings = SettingsModel(defaults: storage.defaults)
        settings.watchFolders = [folder.path]
        settings.watchAutoStart = true
        let watcher = TorrentWatchFolderService()
        var calls = 0
        watcher.start(settings: settings) { _, _, autoStart in
            #expect(autoStart)
            calls += 1
            return true
        }
        defer { watcher.stop() }
        // 先让启动扫描读到空目录，再验证目录事件能唤醒后续扫描。
        try await Task.sleep(for: .milliseconds(200))
        let file = folder.appending(path: "new.magnet")
        try Data(magnet.utf8).write(to: file)
        for _ in 0..<50 where calls == 0 {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(calls == 1)
        watcher.stop()
        try Data(magnet.utf8).write(to: file)
        try await Task.sleep(for: .milliseconds(1100))
        #expect(calls == 1)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test(arguments: [false, true])
    func controllerArchivesOnlyAfterConfirmedEngineAddition(autoStart: Bool) async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let watched = folder.appending(path: "watched", directoryHint: .isDirectory)
        let downloads = folder.appending(path: "downloads", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let file = watched.appending(path: "existing.magnet")
        try Data(magnet.utf8).write(to: file)
        let storage = try TemporaryDefaults(prefix: "WatchFolderController.")
        defer { storage.clean() }
        let settings = SettingsModel(defaults: storage.defaults)
        settings.saveDirectory = downloads.path
        settings.watchFolders = [watched.path]
        settings.watchAutoStart = autoStart
        settings.autoExtract = false
        let configuration = TorrentEngineSettings(listenPort: 0, dht: false, lsd: false, portMapping: false)
        let engine = TorrentEngine(
            stateDirectory: folder.appending(path: "state"),
            binaryURL: Bundle.main.bundleURL.appending(path: "Contents/Helpers/mulee-torrentd"), settings: configuration
        )
        let app = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        app.downloadSettings = settings
        app.bitTorrent = BitTorrentController(engine: engine, model: app, configuration: configuration)
        let coordinator = DownloadCoordinator(model: app, engines: [engine])
        do {
            await coordinator.start(options: EngineOptions(downloadDirectory: downloads))
            #expect(app.engineStates[.bittorrent] == .running)
            if !autoStart {
                for _ in 0..<80 where !app.isShowingNewTask {
                    try await Task.sleep(for: .milliseconds(100))
                }
                #expect(app.isShowingNewTask)
                #expect(app.tasks.isEmpty)
                #expect(FileManager.default.fileExists(atPath: file.path))
                let draft = NewTaskModel(saveDirectory: downloads, autoExtract: false)
                draft.consumePendingText(from: app)
                draft.createTasks(in: app)
                app.isShowingNewTask = false
            }
            for _ in 0..<100 where FileManager.default.fileExists(atPath: file.path) {
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(!FileManager.default.fileExists(atPath: file.path))
            #expect(app.tasks.contains { $0.engineTaskID != nil && $0.sourceLink == magnet })
            #expect(app.bitTorrent?.watchFolders.lastError == nil)
            await coordinator.stop()
        } catch {
            await coordinator.stop()
            throw error
        }
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Mulee-watch-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
