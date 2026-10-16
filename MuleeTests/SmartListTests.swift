import Foundation
import MuleeCore
import Testing
@testable import Mulee

@Suite @MainActor struct SmartListTests {
    @Test func stalledBoundaryTagsTodayErrorsAndTrash() {
        let now = Date(timeIntervalSince1970: 100_000)
        var task = MockData.longTailTask
        task.status = .downloading
        task.lastProgressAt = now.addingTimeInterval(-3600)
        #expect(SidebarItem.stalled.includes(task, now: now))
        task.lastProgressAt = now.addingTimeInterval(-3599)
        #expect(!SidebarItem.stalled.includes(task, now: now))
        task.status = .paused
        task.lastProgressAt = now.addingTimeInterval(-7200)
        #expect(!SidebarItem.stalled.includes(task, now: now))
        task.status = .failed
        #expect(SidebarItem.failed.includes(task))
        task.completedAt = now
        #expect(SidebarItem.completedToday.includes(task, now: now))
        task.tags = ["work", "work", "archive"]
        #expect(SidebarItem.tag("work").includes(task))
        #expect(SidebarItem.counts(in: [task])[.tag("work")] == 1)
        task.deletedAt = now
        #expect(SidebarItem.all.filter([task]).isEmpty)
        #expect(!SidebarItem.failed.includes(task))
        #expect(SidebarItem.recentlyDeleted.filter([task]) == [task])
    }

    @Test func tagsTrimDeduplicateAndCanBeCleared() {
        let task = MockData.longTailTask
        let model = AppModel(tasks: [task], preventsSleepWhileDownloading: false)
        model.setTags(task.id, text: " work,work，archive, , ")
        #expect(model.tasks[0].tags == ["work", "archive"])
        model.setTags(task.id, text: "")
        #expect(model.tasks[0].tags == [])
    }

    @Test func tenThousandTasksKeepOrderAndSinglePassCounts() {
        let tasks = (0..<10_000).map { index in
            var task = MockData.longTailTask
            task.name = "task-\(index)"
            task.tags = ["work"]
            return task
        }
        let counts = SidebarItem.counts(in: tasks)
        #expect(counts[.all] == 10_000)
        #expect(counts[.tag("work")] == 10_000)
        #expect(SidebarItem.tag("work").filter(tasks).map(\.name) == tasks.map(\.name))
    }
}
