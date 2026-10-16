import Foundation
import MuleeCore
import Testing
@testable import Mulee

@Suite @MainActor struct FileProgressTests {
    @Test func publishesActualFileAndWithdrawsForPauseCompletionDeletion() {
        let publisher = DownloadFileProgressPublisher()
        defer { publisher.stop() }
        var task = MockData.longTailTask
        task.kind = .http
        task.status = .downloading
        task.savePath = URL(filePath: "/tmp/.mulee-incomplete/fixture/sample.bin")
        task.totalBytes = 100
        task.receivedBytes = 25
        publisher.update(tasks: [task])
        #expect(publisher.progresses.count == 1)
        let progress = publisher.progresses.values.first
        #expect(progress?.kind == .file)
        #expect(progress?.userInfo[.fileURLKey] as? URL == task.savePath)
        #expect(progress?.userInfo[.fileOperationKindKey] as? Progress.FileOperationKind == .downloading)
        #expect(progress?.fractionCompleted == 0.25)
        for status in [TaskStatus.paused, .completed] {
            task.status = status
            publisher.update(tasks: [task])
            #expect(publisher.progresses.isEmpty)
        }
        task.status = .downloading
        publisher.update(tasks: [task])
        task.deletedAt = .now
        publisher.update(tasks: [task])
        #expect(publisher.progresses.isEmpty)
    }

    @Test func torrentProgressUsesIncompleteStorageAndSkipsCompletedFiles() {
        let publisher = DownloadFileProgressPublisher()
        defer { publisher.stop() }
        var task = MockData.longTailTask
        task.kind = .bittorrent
        task.status = .downloading
        task.writeDirectories = [URL(filePath: "/tmp/fixture")]
        let files = [TorrentFileEntry(index: 0, path: "sample.mp4", size: 100, done: 20, storagePath: "sample.mp4.mulee"),
                     TorrentFileEntry(index: 1, path: "done.bin", size: 10, done: 10)]
        publisher.update(tasks: [task], torrentFiles: [task.id: files])
        #expect(publisher.progresses.count == 1)
        #expect(publisher.progresses.keys.first?.lastPathComponent == "sample.mp4.mulee")
        #expect(publisher.progresses.values.first?.completedUnitCount == 20)
        publisher.update(tasks: [])
        #expect(publisher.progresses.isEmpty)
    }
}
