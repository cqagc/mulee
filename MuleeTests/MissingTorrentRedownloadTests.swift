import Foundation
import MuleeCore
import Testing
@testable import Mulee

@Suite(.serialized) @MainActor
struct MissingTorrentRedownloadTests {
    @Test func missingTorrentRedownloadRechecksTheRetainedEngineTask() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Mulee-bt-redownload-\(UUID())")
        let downloads = root.appending(path: "downloads", directoryHint: .isDirectory)
        let source = downloads.appending(path: "Mulee fixture", directoryHint: .isDirectory)
        let state = root.appending(path: "state", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let payload = Data("Mulee local torrent redownload fixture\n".utf8)
        try payload.write(to: source.appending(path: "fixture.txt"))
        try payload.write(to: source.appending(path: "ignored.txt"))
        let binary = Bundle.main.bundleURL.appending(path: "Contents/Helpers/mulee-torrentd")
        let engine = TorrentEngine(
            stateDirectory: state,
            binaryURL: binary,
            settings: TorrentEngineSettings(listenPort: 0, dht: false, lsd: false, portMapping: false)
        )
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        let defaults = try TemporaryDefaults(prefix: "bt-redownload.")
        defer { defaults.clean() }
        model.downloadSettings = SettingsModel(defaults: defaults.defaults)
        model.downloadSettings?.markIncomplete = false
        let coordinator = DownloadCoordinator(model: model, engines: [engine])
        do {
            await coordinator.start(options: EngineOptions(downloadDirectory: downloads))
            let torrentURL = root.appending(path: "fixture.torrent")
            _ = try await engine.createTorrent(from: source, to: torrentURL)
            let link = try #require(LinkParser.parse(torrentURL.absoluteString).first)
            let metadata = try TorrentFileInfo.parse(data: Data(contentsOf: torrentURL))
            let priorities = metadata.files.map { $0.path.hasSuffix("fixture.txt") ? 4 : 0 }
            await coordinator.add(links: [link], autoExtract: false, directory: downloads, filePriorities: [link: priorities])

            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            var task: DownloadTask?
            while ContinuousClock.now < deadline {
                await coordinator.poll()
                task = model.tasks.first
                if task?.status == .seeding { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            let completed = try #require(task)
            try #require(completed.status == .seeding)
            let oldEngineID = try #require(completed.engineTaskID)
            let output = try #require(completed.savePath)
            #expect(try Data(contentsOf: output.appending(path: "fixture.txt")) == payload)

            try FileManager.default.removeItem(at: output)
            model.refreshTrackedFile(completed.id)
            #expect(model.tasks.first?.fileMissing == true)
            try await coordinator.redownloadMissingFile(completed.id)

            let redownloaded = try #require(model.tasks.first)
            #expect(redownloaded.id == completed.id)
            #expect(redownloaded.engineTaskID == oldEngineID)
            #expect(redownloaded.status == .queued || redownloaded.status == .downloading)
            let retainedFiles = try await engine.files(oldEngineID)
            #expect(retainedFiles.map(\.priority) == priorities)
            #expect(try await engine.snapshots().count == 1)
            let recheckDeadline = ContinuousClock.now.advanced(by: .seconds(10))
            while try await engine.snapshots().first?.receivedBytes != 0, ContinuousClock.now < recheckDeadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(try await engine.snapshots().first?.receivedBytes == 0)
            await coordinator.stop()
        } catch {
            await coordinator.stop()
            throw error
        }
    }
}
