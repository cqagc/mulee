import AppKit
import Foundation
import MuleeCore
import Testing
@testable import Mulee

@MainActor
@Suite struct CreateTorrentTests {
    @Test(arguments: ["big.bin", "source-folder", "existing.torrent"])
    func savePanelKeepsSourceNameAndRequiresTorrentType(name: String) throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: name)

        let panel = CreateTorrentView.makeSavePanel(for: source)

        #expect(panel.nameFieldStringValue == name + ".torrent")
        #expect(panel.allowedContentTypes.count == 1)
        #expect(panel.allowedContentTypes.first?.identifier == "org.bittorrent.torrent")
        #expect(panel.allowedContentTypes.first?.preferredFilenameExtension == "torrent")
        #expect(!panel.allowsOtherFileTypes)
        #expect(!panel.canSelectHiddenExtension)
        #expect(!panel.isExtensionHidden)
        #expect(panel.directoryURL?.resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path)
    }

    @Test func creationWindowParticipatesInWindowMenu() {
        let window = CreateTorrentPanel.makeWindow()

        // 不显示测试窗口；AppKit 只有在窗口可见时才会让 canBecomeMain 返回 true。
        #expect(!window.isExcludedFromWindowsMenu)
        #expect(!(window is NSPanel))
        #expect(window.styleMask.contains(.titled))
        #expect(window.canBecomeKey)
        #expect(!window.isVisible)
    }

    @Test(arguments: ["same-file", "file-symlink", "same-folder", "inside-folder", "folder-symlink", "nested-folder"])
    func rejectsDestinationsThatContainOrReplaceSource(scenario: String) async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let directory = folder.appending(path: "source", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "original.torrent")
        let original = Data("original content".utf8)
        try original.write(to: file)
        let alias = folder.appending(path: "alias")
        let source: URL
        let destination: URL
        switch scenario {
        case "same-file":
            source = file
            destination = file
        case "file-symlink":
            source = file
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
            destination = alias
        case "same-folder":
            source = directory
            destination = directory
        case "folder-symlink":
            source = directory
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
            destination = alias.appending(path: "created.torrent")
        case "nested-folder":
            source = directory
            let nested = directory.appending(path: "nested")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            destination = nested.appending(path: "created.torrent")
        default:
            source = directory
            destination = directory.appending(path: "created.torrent")
        }
        let before = try FileManager.default.subpathsOfDirectory(atPath: folder.path).sorted()
        let model = CreateTorrentModel()
        model.source = source
        var creatorCalled = false

        model.start(to: destination) { _, temporary, _, _, _ in
            creatorCalled = true
            try Data("torrent".utf8).write(to: temporary)
        } seed: { _, _ in Issue.record("Unexpected seeding") }
        #expect(!model.isWorking)
        #expect(model.job == nil)
        await model.job?.value

        #expect(!creatorCalled)
        #expect(model.issue != nil)
        #expect(model.output == nil)
        #expect(try Data(contentsOf: file) == original)
        #expect(try FileManager.default.subpathsOfDirectory(atPath: folder.path).sorted() == before)
    }

    @Test func allowsSiblingFolderWithSharedNamePrefix() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "source")
        let sibling = folder.appending(path: "source-other")
        for directory in [source, sibling] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let model = CreateTorrentModel()
        model.source = source
        let output = sibling.appending(path: "created.torrent")

        model.start(to: output) { _, temporary, _, _, _ in
            try Data("torrent".utf8).write(to: temporary)
        } seed: { _, _ in Issue.record("Unexpected seeding") }
        await model.job?.value

        #expect(model.output == output)
        #expect(model.issue == nil)
    }

    @Test func publishesCompletedTorrentAndSeedsFromOriginalDirectory() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "source")
        let output = folder.appending(path: "fixture.torrent")
        let model = CreateTorrentModel()
        model.source = source
        model.trackerText = "https://tracker.invalid/announce\n\n"
        model.isPrivate = true
        model.startsSeeding = true
        var seeded = false
        model.start(to: output) { input, temporaryOutput, isPrivate, trackers, progress in
            #expect(input == source)
            #expect(temporaryOutput != output)
            #expect(isPrivate)
            #expect(trackers == ["https://tracker.invalid/announce"])
            let snapshot = TorrentCreationProgress(completedPieces: 2, totalPieces: 4, processedBytes: 512, totalBytes: 1024)
            await progress(snapshot)
            #expect(model.progress == snapshot)
            #expect(model.progress?.fractionCompleted == 0.5)
            try Data("fixture".utf8).write(to: temporaryOutput)
        } seed: { torrent, directory in
            #expect(torrent == output)
            #expect(directory.resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path)
            seeded = true
        }
        await model.job?.value
        #expect(model.output == output)
        #expect(!model.isWorking)
        #expect(model.issue == nil)
        #expect(model.progress?.fractionCompleted == 1)
        #expect(model.progress?.processedBytes == 1024)
        #expect(seeded)
        #expect(try String(contentsOf: output, encoding: .utf8) == "fixture")
    }

    @Test func cancellationCleansLateEngineOutput() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appending(path: "cancelled.torrent")
        let model = CreateTorrentModel()
        model.source = folder.appending(path: "source")
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        var temporaryOutput: URL?
        var seeded = false
        var engineTaskWasCancelled = false
        model.startsSeeding = true
        model.start(to: output) { _, temporary, _, _, progress in
            temporaryOutput = temporary
            for await _ in stream { break }
            engineTaskWasCancelled = Task.isCancelled
            await progress(TorrentCreationProgress(completedPieces: 1, totalPieces: 2, processedBytes: 1, totalBytes: 2))
            try Data("late result".utf8).write(to: temporary)
        } seed: { _, _ in seeded = true }
        while temporaryOutput == nil { await Task.yield() }
        model.cancel()
        continuation.yield(())
        continuation.finish()
        await model.job?.value
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(!FileManager.default.fileExists(atPath: try #require(temporaryOutput).path))
        #expect(!seeded)
        #expect(model.output == nil)
        #expect(engineTaskWasCancelled)
        #expect(model.progress == nil)
    }

    @Test func failedCreationAndExistingDestinationArePreserved() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appending(path: "existing.torrent")
        try Data("original".utf8).write(to: output)
        let model = CreateTorrentModel()
        model.source = folder.appending(path: "source")
        model.start(to: output) { _, temporary, _, _, _ in
            try Data("new".utf8).write(to: temporary)
        } seed: { _, _ in Issue.record("Unexpected seeding") }
        await model.job?.value
        #expect(model.issue != nil)
        #expect(model.output == nil)
        #expect(try String(contentsOf: output, encoding: .utf8) == "original")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["existing.torrent"])
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Mulee-create-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
