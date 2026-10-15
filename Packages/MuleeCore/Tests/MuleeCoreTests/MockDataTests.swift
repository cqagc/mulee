import Testing
@testable import MuleeCore

/// 示例数据要和原型保持一致，界面开发依赖这些数字。
@Suite struct MockDataTests {
    @Test func prototypeHasEightTasks() {
        #expect(MockData.tasks.count == 8)
    }

    @Test func longTailTaskIsWaitingForSources() {
        #expect(MockData.longTailTask.status == .waitingForSources)
        #expect(MockData.tasks.contains { $0.id == MockData.longTailTask.id })
    }

    @Test func sightingsCoverFourteenDays() {
        for task in MockData.tasks {
            if case .ed2k(_, let longTail) = task.detail {
                #expect(longTail.dailySourceSightings.count == 14)
            }
        }
    }
}
