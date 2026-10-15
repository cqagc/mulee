import MuleeCore
import Testing
@testable import Mulee

@MainActor
@Suite struct SidebarFilterTests {
    @Test func statusCountsReflectMockTasks() {
        let tasks = MockData.tasks

        #expect(SidebarItem.all.filter(tasks).count == 8)
        #expect(SidebarItem.downloading.filter(tasks).count == 4)
        #expect(SidebarItem.waitingForSources.filter(tasks).count == 2)
        #expect(SidebarItem.seeding.filter(tasks).count == 1)
        #expect(SidebarItem.completed.filter(tasks).count == 1)
        #expect(SidebarItem.subtitle(for: tasks) == "8 个任务 · 4 个进行中")
    }

    @Test(arguments: [SidebarItem.http, .bittorrent, .ed2k, .video])
    func kindsAreIndependentOfStatus(_ item: SidebarItem) {
        let tasks = item.filter(MockData.tasks)

        #expect(tasks.count == 2)
        #expect(tasks.allSatisfy { $0.kind.rawValue == item.rawValue })
    }

    @Test func downloadingIncludesPostProcessingButExcludesSeeding() {
        let statuses = Set(SidebarItem.downloading.filter(MockData.tasks).map(\.status))

        #expect(statuses == [.downloading, .postProcessing, .extracting])
    }

    @Test func searchUsesTaskNameAndCurrentCategory() {
        let tasks = MockData.tasks

        #expect(SidebarItem.all.filter(tasks, search: "UBUNTU").count == 1)
        #expect(SidebarItem.http.filter(tasks, search: "ubuntu").count == 1)
        #expect(SidebarItem.ed2k.filter(tasks, search: "ubuntu").isEmpty)
        #expect(SidebarItem.all.filter(tasks, search: "超魔法").map(\.id) == [MockData.longTailTask.id])
        #expect(SidebarItem.all.filter(tasks, search: "https://").isEmpty)
        #expect(SidebarItem.all.filter(tasks, search: "不存在的任务").isEmpty)
    }

    @Test func pausedTasksRemainInAllAndTheirKind() {
        var task = MockData.longTailTask
        task.status = .paused

        #expect(SidebarItem.all.includes(task))
        #expect(SidebarItem.ed2k.includes(task))
        #expect(!SidebarItem.downloading.includes(task))
        #expect(!SidebarItem.waitingForSources.includes(task))
        #expect(SidebarItem.subtitle(for: [task]) == "1 个任务 · 0 个进行中")
    }

    @Test func emptyCategoryHasAccurateSubtitle() {
        #expect(SidebarItem.all.filter([]).isEmpty)
        #expect(SidebarItem.subtitle(for: []) == "0 个任务 · 0 个进行中")
        #expect(SidebarItem.all.navigationTitle == "全部任务")
    }
}
