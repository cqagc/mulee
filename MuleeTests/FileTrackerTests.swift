import Foundation
import MuleeCore
import Testing
@testable import Mulee

@Suite @MainActor struct FileTrackerTests {
    private func fixtureDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "Mulee-open-action-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func openActionUsesFinderForTorrentFoldersAndPartialFiles() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        var torrent = MockData.tasks[1]
        let torrentPath = directory.appending(path: "torrent-folder", directoryHint: .isDirectory)
        torrent.savePath = torrentPath
        try FileManager.default.createDirectory(at: torrentPath, withIntermediateDirectories: true)
        #expect(TaskActions.openAction(for: torrent, defaultDirectory: directory) == .open(torrentPath))

        var partial = MockData.tasks[0]
        partial.status = .downloading
        let partialPath = directory.appending(path: "partial.iso")
        partial.savePath = partialPath
        try Data([0]).write(to: partialPath)
        #expect(TaskActions.openAction(for: partial, defaultDirectory: directory) == .reveal(partialPath))
    }

    @Test func openActionOpensCompletedVideoAndDocumentWithDefaultApplications() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        var video = MockData.tasks[3]
        video.status = .completed
        let videoPath = directory.appending(path: "video.mp4")
        video.savePath = videoPath
        try Data([0]).write(to: videoPath)
        #expect(TaskActions.openAction(for: video, defaultDirectory: directory) == .open(videoPath))

        var document = MockData.tasks[0]
        document.status = .completed
        let documentPath = directory.appending(path: "document.pdf")
        document.savePath = documentPath
        try Data([0]).write(to: documentPath)
        #expect(TaskActions.openAction(for: document, defaultDirectory: directory) == .open(documentPath))
    }

    @Test func openActionResolvesMovedBookmarksAndRejectsTrash() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appending(path: "original.mp4")
        let moved = directory.appending(path: "moved.mp4")
        try Data([0]).write(to: original)

        var video = MockData.tasks[3]
        video.status = .completed
        video.savePath = original
        FileTracker.capture(&video)
        try FileManager.default.moveItem(at: original, to: moved)
        guard case .open(let resolved) = TaskActions.openAction(for: video, defaultDirectory: directory) else {
            Issue.record("Expected to open the moved video")
            return
        }
        #expect(resolved.standardizedFileURL == moved.standardizedFileURL)

        video.deletedAt = .now
        #expect(TaskActions.openAction(for: video, defaultDirectory: directory) == nil)
    }

    @Test func openActionFallsBackToExistingParentOrWriteDirectory() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        var task = MockData.tasks[0]
        task.status = .downloading
        task.savePath = directory.appending(path: "missing.bin")
        #expect(TaskActions.openAction(for: task, defaultDirectory: directory) == .open(directory))

        task.savePath = nil
        task.writeDirectories = [directory]
        #expect(TaskActions.openAction(for: task, defaultDirectory: directory) == .open(directory))
    }

    @Test func bookmarkFollowsMoveAndReportsDeletionWithoutRemovingRecord() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original.zip")
        let moved = directory.appendingPathComponent("moved.zip")
        try Data("archive".utf8).write(to: original)
        var task = MockData.longTailTask
        task.status = .completed
        task.savePath = original
        FileTracker.capture(&task)
        #expect(task.fileBookmark != nil)
        try FileManager.default.moveItem(at: original, to: moved)
        FileTracker.resolve(&task)
        #expect(task.savePath?.standardizedFileURL == moved.standardizedFileURL)
        #expect(task.fileMissing == false)
        try FileManager.default.removeItem(at: moved)
        FileTracker.resolve(&task)
        #expect(task.fileMissing == true)
        let model = AppModel(tasks: [task], preventsSleepWhileDownloading: false)
        model.refreshTrackedFile(task.id)
        #expect(model.tasks.count == 1)
        #expect(model.tasks[0].fileMissing == true)
    }

    @Test func bookmarkTracksUserMovingFileToTrashAndPuttingItBack() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appending(path: "trash-me.zip")
        try Data("archive".utf8).write(to: original)
        var task = MockData.longTailTask
        task.status = .completed
        task.savePath = original
        FileTracker.capture(&task)

        var trashed: NSURL?
        try FileManager.default.trashItem(at: original, resultingItemURL: &trashed)
        let trashURL = try #require(trashed) as URL
        defer { try? FileManager.default.removeItem(at: trashURL) }
        FileTracker.resolve(&task)
        #expect(task.fileMissing == true)
        #expect(task.savePath == original)
        #expect(!FileManager.default.fileExists(atPath: original.path))
        #expect(FileManager.default.fileExists(atPath: trashURL.path))

        try FileManager.default.moveItem(at: trashURL, to: original)
        FileTracker.resolve(&task)
        #expect(task.fileMissing == false)
        #expect(task.savePath?.standardizedFileURL == original.standardizedFileURL)
    }

    @Test func startupResolvesMovedBookmarkAndRetainsMissingHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original.pdf")
        let moved = directory.appendingPathComponent("moved.pdf")
        try Data([1]).write(to: original)
        var task = MockData.longTailTask
        task.status = .completed
        task.savePath = original
        FileTracker.capture(&task)
        let store = TaskHistoryStore(directory: directory.appendingPathComponent("history"))
        try store.flush(tasks: [task])
        try FileManager.default.moveItem(at: original, to: moved)
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        model.loadTaskHistory(from: store)
        #expect(model.tasks.first?.savePath?.standardizedFileURL == moved.standardizedFileURL)
        try FileManager.default.removeItem(at: moved)
        model.refreshTrackedFile(task.id)
        #expect(model.tasks.first?.fileMissing == true)
        #expect(model.tasks.count == 1)
        model.flushTaskHistory()
    }
}
