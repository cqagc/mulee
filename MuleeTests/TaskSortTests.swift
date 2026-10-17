import Foundation
import MuleeCore
import Testing
@testable import Mulee

@Suite @MainActor struct TaskSortTests {
    private func task(_ name: String, size: Int64 = 100, received: Int64 = 0, speed: Int64 = 0) -> DownloadTask {
        DownloadTask(
            name: name, fileExtension: "bin", kind: .http, status: .queued,
            totalBytes: size, receivedBytes: received, downloadRate: speed,
            detail: .http(connections: 0), postDownload: PostDownloadInfo(autoExtract: false),
            sourceLink: "https://example.org/file.bin"
        )
    }

    @Test func everyKeyAndDirection() {
        var first = task("Alpha", size: 100, received: 10, speed: 10)
        var second = task("beta", size: 200, received: 100, speed: 20)
        first.createdAt = Date(timeIntervalSince1970: 10)
        second.createdAt = Date(timeIntervalSince1970: 20)
        first.status = .downloading
        second.status = .paused
        for key in TaskSort.Key.allCases {
            #expect(TaskSort(key: key, ascending: true).sorted([second, first]).map(\.id) == [first.id, second.id])
            #expect(TaskSort(key: key, ascending: false).sorted([first, second]).map(\.id) == [second.id, first.id])
        }
        #expect(TaskSort(TaskSort.defaultValue).sorted([first, second]).first?.id == second.id)
    }

    @Test func stableTiesAndLegacyDates() {
        let first = task("same")
        var second = task("same")
        second.createdAt = first.createdAt
        for key in TaskSort.Key.allCases {
            for ascending in [true, false] {
                #expect(TaskSort(key: key, ascending: ascending).sorted([first, second]).map(\.id) == [first.id, second.id])
            }
        }
        var legacy = [first, second]
        for index in legacy.indices { legacy[index].createdAt = nil }
        #expect(TaskSort(TaskSort.defaultValue).sorted(legacy).map(\.id) == [first.id, second.id])
        #expect(TaskSort(key: .added, ascending: true).sorted(legacy).map(\.id) == [second.id, first.id])
        #expect(TaskSort("invalid") == TaskSort(TaskSort.defaultValue))
        #expect(TaskSort("name.invalid") == TaskSort(TaskSort.defaultValue))
        #expect(TaskSort("speed.ascending").value == "speed.ascending")
    }

    @Test func unknownSizesAndProgressHaveStableOrderAndQueueIsUnchanged() {
        var unknown = task("unknown")
        unknown.totalBytes = nil
        unknown.queuePosition = 10
        let known = task("known", received: 50)
        #expect(TaskSort(key: .size, ascending: true).sorted([known, unknown]).first?.id == unknown.id)
        #expect(TaskSort(key: .progress, ascending: false).sorted([unknown, known]).first?.id == known.id)
        #expect(unknown.queuePosition == 10)
        #expect(TaskSort(key: .speed, ascending: true).sorted([]).isEmpty)
    }

    @Test func sortingTenThousandTasksTakesLessThanFiftyMilliseconds() {
        let tasks = (0..<10_000).map { index in
            task("File-\(10_000 - index)", size: Int64(index + 1), received: Int64(index / 2), speed: Int64(index))
        }
        let clock = ContinuousClock()
        for key in TaskSort.Key.allCases {
            let start = clock.now
            let result = TaskSort(key: key, ascending: true).sorted(tasks)
            let elapsed = start.duration(to: clock.now)
            #expect(result.count == 10_000)
            #expect(elapsed < .milliseconds(50), "\(key.rawValue): \(elapsed)")
            print("TaskSort 10000 \(key.rawValue): \(elapsed)")
        }
    }

    @Test func queueSettingsDefaultsPersistenceAndInvalidOverrides() throws {
        let storage = try TemporaryDefaults(prefix: "queue-settings.")
        defer { storage.clean() }
        let settings = SettingsModel(defaults: storage.defaults)
        #expect(settings.stalledYieldMinutes == 10)
        #expect(settings.taskSort == TaskSort.defaultValue)
        settings.stalledYieldMinutes = 0
        settings.taskSort = "speed.ascending"
        let restored = SettingsModel(defaults: storage.defaults)
        #expect(restored.stalledYieldMinutes == 0)
        #expect(restored.taskSort == "speed.ascending")
        #expect(storage.defaults.integer(forKey: "download.stalledYieldMinutes") == 0)
        #expect(storage.defaults.string(forKey: "ui.taskSort") == "speed.ascending")
        settings.stalledYieldMinutes = -1
        #expect(settings.stalledYieldMinutes == 0)
        storage.defaults.set(-30, forKey: "download.stalledYieldMinutes")
        #expect(SettingsModel(defaults: storage.defaults).stalledYieldMinutes == 0)
    }

    @Test func sortingAppliesAfterSmartListTagAndSearchFilters() {
        var first = task("Alpha")
        first.status = .failed
        first.tags = ["Example"]
        var second = task("beta")
        second.status = .failed
        second.tags = ["Example"]
        let unrelated = task("other")
        let tasks = [second, unrelated, first]
        let sort = TaskSort(key: .name, ascending: true)
        for category in [SidebarItem.failed, .tag("Example"), .tagged] {
            #expect(sort.sorted(category.filter(tasks)).map(\.id) == [first.id, second.id])
        }
        #expect(sort.sorted(SidebarItem.all.filter(tasks, search: "Alpha")).map(\.id) == [first.id])
    }
}
