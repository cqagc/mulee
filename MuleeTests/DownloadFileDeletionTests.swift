import Foundation
import MuleeCore
import Testing
@testable import Mulee

@Suite @MainActor
struct DownloadFileDeletionTests {
    @Test func removingCompletedHTTPWithFilesMovesOnlyItsOutputToTrash() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appending(path: "one.bin")
        let sibling = root.appending(path: "two.bin")
        try Data("one".utf8).write(to: output)
        try Data("two".utf8).write(to: sibling)

        let bookmark = try output.bookmarkData()
        defer { removeTrashedFixture(bookmark) }
        var task = makeTask(name: "one.bin", kind: .http, path: output, engineID: nil)
        task.sourceLink = "https://example.invalid/one.bin"
        let model = AppModel(tasks: [task], preventsSleepWhileDownloading: false)
        let coordinator = DownloadCoordinator(model: model, engines: [])
        await coordinator.start(options: EngineOptions(downloadDirectory: root))
        await coordinator.remove(task.id, deleteFiles: true)
        await coordinator.stop()

        #expect(model.tasks.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(FileManager.default.fileExists(atPath: sibling.path))
    }

    @Test func removingWithoutFilesKeepsCompletedOutputAndMovesRecordToTrash() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appending(path: "one.mp4")
        try Data("video".utf8).write(to: output)
        let task = makeTask(name: "one.mp4", kind: .video, path: output, engineID: nil)
        let model = AppModel(tasks: [task], preventsSleepWhileDownloading: false)
        let coordinator = DownloadCoordinator(model: model, engines: [])
        await coordinator.start(options: EngineOptions(downloadDirectory: root))
        await coordinator.remove(task.id, deleteFiles: false)
        await coordinator.stop()

        #expect(model.tasks.first?.deletedAt != nil)
        #expect(FileManager.default.fileExists(atPath: output.path))
    }

    @Test func failedEngineDeleteKeepsRecordAndOutput() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appending(path: "one.mp4")
        try Data("video".utf8).write(to: output)
        var task = makeTask(name: "one.mp4", kind: .video, path: output, engineID: "video-1")
        task.status = .downloading
        task.completedAt = nil
        task.receivedBytes = 2
        let engine = FakeEngine(kind: .video)
        await engine.failOperations(with: .notRunning)
        let model = AppModel(tasks: [task], preventsSleepWhileDownloading: false)
        let coordinator = DownloadCoordinator(model: model, engines: [engine])
        await coordinator.start(options: EngineOptions(downloadDirectory: root))
        await coordinator.remove(task.id, deleteFiles: true)
        await coordinator.stop()

        #expect(model.tasks.first?.deletedAt == nil)
        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(model.tasks.first?.errorMessage != nil)
    }

    @Test func archivedHTTPResultProtectsReplacementAtOldName() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appending(path: "original.bin")
        let moved = root.appending(path: "moved.bin")
        try Data("original".utf8).write(to: old)
        var task = makeTask(name: "original.bin", kind: .http, path: old, engineID: "retired")
        FileTracker.capture(&task)
        let bookmark = try #require(task.fileBookmark)
        defer { removeTrashedFixture(bookmark) }
        try FileManager.default.moveItem(at: old, to: moved)
        try Data("replacement".utf8).write(to: old)
        let model = AppModel(tasks: [task], preventsSleepWhileDownloading: false)
        let coordinator = DownloadCoordinator(model: model, engines: [])
        await coordinator.remove(task.id, deleteFiles: true)
        #expect(model.tasks.first?.id == task.id)
        #expect(model.deletionIssue != nil)
        #expect(try Data(contentsOf: moved) == Data("original".utf8))
        #expect(try Data(contentsOf: old) == Data("replacement".utf8))
    }

    @Test func missingManifestCannotDeleteAnUnrelatedFileInTorrentDirectory() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let unrelated = root.appending(path: "my-notes.txt")
        try Data("keep".utf8).write(to: unrelated)
        var task = makeTask(name: "fixture", kind: .bittorrent, path: root, engineID: nil)
        FileTracker.capture(&task)
        let model = AppModel(tasks: [task], preventsSleepWhileDownloading: false)
        let coordinator = DownloadCoordinator(model: model, engines: [])
        await coordinator.remove(task.id, deleteFiles: true)
        #expect(model.tasks.first?.id == task.id)
        #expect(model.deletionIssue != nil)
        #expect(try Data(contentsOf: unrelated) == Data("keep".utf8))
    }

    private func removeTrashedFixture(_ bookmark: Data) {
        var stale = false
        if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                              relativeTo: nil, bookmarkDataIsStale: &stale), FileTracker.isInTrash(url) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func makeRoot() throws -> URL {
        let root = URL.temporaryDirectory.appending(path: "Mulee-file-delete-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeTask(name: String, kind: TaskKind, path: URL, engineID: String?) -> DownloadTask {
        DownloadTask(
            name: name, fileExtension: path.pathExtension, kind: kind, status: .completed,
            totalBytes: 5, receivedBytes: 5, detail: kind == .video
                ? .video(site: .other, quality: "兼容优先", danmakuToASS: false)
                : .http(connections: 0), postDownload: PostDownloadInfo(autoExtract: false),
            sourceLink: "https://example.invalid/\(name)", engineTaskID: engineID, savePath: path
        )
    }
}
