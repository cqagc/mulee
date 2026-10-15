import Foundation
import MuleeCore
import Testing
@testable import Mulee

@Suite @MainActor struct ExtractionPresentationTests {
    @Test func reportsWaitingFailureAndProductsWithoutFailingDownload() async throws {
        let context = try ExtractionTestContext()
        var task = try context.task(status: .completed)
        task.postDownload.extractionState = .waitingForVolumes
        #expect(TaskPresentation(task: task).statusTitle == "等待其余分卷")
        #expect(TaskPresentation(task: task).progressStyle == .waiting)
        task.postDownload.extractionState = .failed
        task.postDownload.extractionFailure = "密码都不对"
        #expect(TaskPresentation(task: task).statusTitle == "解压未完成")
        #expect(TaskPresentation(task: task).statusSubtitle == "密码都不对")
        task.postDownload.extractionState = .succeeded
        task.postDownload.extractedItems = [context.root.appendingPathComponent("星雲資料")]
        task.postDownload.filenameEncoding = "Big5"
        let presentation = TaskPresentation(task: task)
        #expect(presentation.statusTitle == "已解压")
        #expect(presentation.statusSubtitle == "星雲資料")
        #expect(presentation.filenameEncoding == "Big5")
        #expect(presentation.extractedItems.count == 1)
        try await context.clean()
    }
}
