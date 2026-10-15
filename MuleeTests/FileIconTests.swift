import MuleeCore
import SwiftUI
import Testing
@testable import Mulee

@MainActor
@Suite struct FileIconTests {
    @Test(arguments: [
        (TaskStatus.downloading, FileIconState.downloading(progress: 0.4)),
        (.queued, .downloading(progress: 0.4)), (.paused, .downloading(progress: 0.4)),
        (.failed, .attention(progress: 0.4)), (.waitingForSources, .attention(progress: 0.4)),
        (.engineUnavailable, .engineUnavailable(progress: 0.4)),
        (.completed, .completed), (.extracting, .completed), (.postProcessing, .completed), (.seeding, .completed)
    ])
    func statusMapping(_ status: TaskStatus, _ expected: FileIconState) {
        let state = FileIconState(status: status, progress: 0.4)
        #expect(state == expected)
    }

    @Test func taskProgressUsesReceivedBytes() {
        var task = MockData.longTailTask
        task.status = .downloading
        task.totalBytes = 100
        task.receivedBytes = 40
        #expect(FileIconState(task: task).progress == 0.4)
        task.totalBytes = nil
        #expect(FileIconState(task: task).progress == 0)
    }

    @Test(arguments: [(-1.0, 0.0), (0.4, 0.4), (1.5, 1.0), (.nan, 0.0), (.infinity, 0.0)])
    func boundedProgress(_ input: Double, _ expected: Double) {
        let state = FileIconState.downloading(progress: input)
        #expect(state.progress == expected)
    }

    @Test(arguments: [
        (CGFloat(64), [CGFloat(4.5), 3.5]), (48, [3.375, 2.625]),
        (32, [2.5, 2]), (24, [1.875, 1.5]), (16, [1.5, 1.25])
    ] as [(CGFloat, [CGFloat])])
    func dashParameters(_ size: CGFloat, _ expected: [CGFloat]) {
        let metrics = FileIconMetrics(size: size)
        #expect(metrics.dash == expected)
        #expect(metrics.lineWidth == 2.5 * size / 64)
        #expect(metrics.side == 50 * size / 64)
    }

    @Test(arguments: FileCategory.allCases, [CGFloat(16), 32, 47, 48, 64])
    func badgeVisibility(_ category: FileCategory, _ size: CGFloat) {
        let supportsBadge: Set<FileCategory> = [.video, .audio, .archive, .diskImage, .image, .ebook]
        let text = category.badgeText(filenameExtension: "webm", size: size)
        #expect((text != nil) == (size >= 48 && supportsBadge.contains(category)))
        if let text { #expect(text == "WEBM") }
    }

    @Test func badgeLimitsAndMissingExtension() {
        #expect(FileCategory.archive.badgeText(filenameExtension: "longextension", size: 64) == "LONG")
        #expect(FileCategory.video.badgeText(filenameExtension: nil, size: 64) == nil)
        #expect(FileCategory.video.badgeText(filenameExtension: "", size: 64) == nil)
        #expect(FileCategory.video.badgeText(filenameExtension: "  ", size: 64) == nil)
    }
}
