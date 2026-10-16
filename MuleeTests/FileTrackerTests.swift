import Foundation
import MuleeCore
import Testing
@testable import Mulee

@Suite @MainActor struct FileTrackerTests {
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
