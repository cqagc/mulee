import MuleeCore
import Testing
@testable import Mulee

@Suite struct MenuBarPresentationTests {
    private func task(_ status: TaskStatus, rate: Int64 = 0) -> DownloadTask {
        var task = MockData.tasks[0]
        task.status = status
        task.downloadRate = rate
        return task
    }

    @Test func visibleTasksOnlyIncludeActiveStatuses() {
        let tasks = [task(.downloading), task(.paused), task(.postProcessing), task(.extracting), task(.completed), task(.seeding)]
        let visible = MenuBarPresentation(tasks: tasks).visibleTasks
        #expect(visible.map(\.status) == [.downloading, .postProcessing, .extracting])
    }

    @Test func visibleTasksCappedAtFour() {
        let tasks = (0..<6).map { _ in task(.downloading) }
        #expect(MenuBarPresentation(tasks: tasks).visibleTasks.count == 4)
    }

    @Test func trailingTextFollowsStatus() {
        #expect(MenuBarPresentation.trailingText(for: task(.postProcessing)) == "合并中")
        #expect(MenuBarPresentation.trailingText(for: task(.extracting)) == "解压中")
        #expect(MenuBarPresentation.trailingText(for: task(.downloading, rate: 1_000_000)).hasSuffix("/s"))
    }

    @Test func waitingSourceCount() {
        let tasks = [task(.waitingForSources), task(.waitingForSources), task(.downloading)]
        #expect(MenuBarPresentation(tasks: tasks).waitingSourceCount == 2)
        #expect(MenuBarPresentation(tasks: [task(.downloading)]).waitingSourceCount == 0)
    }

    @Test func pauseResumeAction() {
        #expect(MenuBarPresentation(tasks: [task(.downloading)]).pauseResumeAction == .pauseAll)
        #expect(MenuBarPresentation(tasks: [task(.downloading), task(.paused)]).pauseResumeAction == .resumeAll)
    }

    @Test func emptyState() {
        #expect(MenuBarPresentation(tasks: []).isEmpty)
        #expect(!MenuBarPresentation(tasks: MockData.tasks).isEmpty)
    }

    @Test func mockDataShowsAtMostFourTasks() {
        #expect(MenuBarPresentation(tasks: MockData.tasks).visibleTasks.count <= 4)
    }
}
