import Foundation
import MuleeCore
import Testing
@testable import Mulee

@Suite @MainActor struct StreamingPlaybackTests {
    @Test func completedFileEndsBufferingEvenWithoutContiguousProgress() {
        let file = TorrentFileEntry(index: 0, path: "sample.mp4", size: 100_000_000, done: 100_000_000)
        #expect(StreamingPlayback.bufferProgress(file: file) == 1)
        var task = MockData.tasks[0]
        task.status = .completed
        #expect(!StreamingPlayback.showsBuffering(task: task, progress: 0.2))
        task.status = .seeding
        #expect(!StreamingPlayback.showsBuffering(task: task, progress: 0.2))
    }

    @Test func outOfOrderDownloadProgressUsesThePlaybackTarget() {
        let size: Int64 = 100_000_000
        let partialHead = TorrentFileEntry(index: 0, path: "sample.mp4", size: size, done: 87_000_000, contiguousDone: 2_500_000)
        let bufferedHead = TorrentFileEntry(index: 0, path: "sample.mp4", size: size, done: 87_000_000, contiguousDone: 5_000_000)
        #expect(StreamingPlayback.bufferProgress(file: partialHead) == 0.5)
        #expect(StreamingPlayback.bufferProgress(file: bufferedHead) == 1)
    }

    @Test(arguments: ["mp4", "mkv", "mov", "m4v", "webm", "avi", "ts", "flv", "MP4"])
    func videoExtensions(ext: String) {
        #expect(StreamingPlayback.isVideo("sample.\(ext)"))
        #expect(!StreamingPlayback.isVideo("sample.zip"))
    }

    @Test func thresholdsUseSmallerOfTwentyMBAndFivePercent() {
        #expect(StreamingPlayback.bufferThreshold(size: 1_000_000_000) == 20_000_000)
        #expect(StreamingPlayback.bufferThreshold(size: 100_000_000) == 5_000_000)
        #expect(StreamingPlayback.bufferThreshold(size: 1) == 1)
        #expect(StreamingPlayback.bufferThreshold(size: 0) == 0)
    }

    @Test func playerPreferenceUsesInjectedInstalledApplications() {
        #expect(StreamingPlayback.preferredPlayer(installed: ["org.videolan.vlc", "com.colliderli.iina"]) == "com.colliderli.iina")
        #expect(StreamingPlayback.preferredPlayer(installed: ["org.videolan.vlc"]) == "org.videolan.vlc")
        #expect(StreamingPlayback.preferredPlayer(installed: ["com.apple.QuickTimePlayerX"]) == nil)
    }

    @Test func HTTPPlaysDuringDownloadAndVideoRequiresFinishedProduct() {
        var task = MockData.longTailTask
        task.kind = .http
        task.name = "sample.mp4"
        task.savePath = URL(filePath: "/tmp/sample.mp4")
        task.status = .downloading
        task.engineTaskID = "http-fixture"
        #expect(StreamingPlayback.canPlay(task))
        task.status = .paused
        #expect(!StreamingPlayback.canPlay(task))
        task.status = .completed
        #expect(StreamingPlayback.canPlay(task))
        task.savePath = URL(filePath: "/tmp/.mulee-incomplete/task/sample.mp4")
        #expect(!StreamingPlayback.canPlay(task))
        task.kind = .video
        task.savePath = URL(filePath: "/tmp/sample.webm")
        #expect(StreamingPlayback.canPlay(task))
        task.kind = .bittorrent
        task.engineTaskID = "fixture"
        task.name = "files"
        task.status = .downloading
        #expect(!StreamingPlayback.canPlay(task))
        let file = TorrentFileEntry(index: 2, path: "files/sample.mkv", size: 100)
        #expect(StreamingPlayback.canPlay(task, files: [file]))
        task.deletedAt = .now
        #expect(!StreamingPlayback.canPlay(task, files: [file]))
    }

    @Test func actualStoragePathIsUsedForStreaming() {
        var task = MockData.longTailTask
        task.writeDirectories = [URL(filePath: "/tmp/downloads")]
        let file = TorrentFileEntry(index: 0, path: "sample.mp4", size: 100, storagePath: "sample.mp4.mulee", contiguousDone: 5)
        #expect(StreamingPlayback.fileURL(task: task, file: file)?.path == "/tmp/downloads/sample.mp4.mulee")
    }
}
