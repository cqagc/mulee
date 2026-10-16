import Foundation
import MuleeCore
import Testing
@testable import Mulee

@Suite @MainActor struct TransferStatisticsStoreTests {
    private func root() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "TransferStatistics-\(UUID().uuidString)")
    }

    private func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func task(_ index: Int, kind: TaskKind = .http) -> DownloadTask {
        var task = DownloadTask(link: LinkParser.parse("https://example.com/file\(index)").first!, autoExtract: false)
        task.kind = kind
        task.status = .downloading
        task.receivedBytes = 100
        task.downloadRate = 20
        task.uploadRate = 10
        return task
    }

    @Test func accumulatesDeltasByKindAndDayExcludingTrashAndImportedHistory() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        var clock = try #require(ISO8601DateFormatter().date(from: "2026-10-16T23:59:58Z"))
        let store = TransferStatisticsStore(fileURL: root.appending(path: "statistics.json"), now: { clock }, calendar: calendar())
        var tasks = TaskKind.allCases.enumerated().map { task($0.offset, kind: $0.element) }
        var trashed = task(99)
        trashed.deletedAt = clock
        tasks.append(trashed)
        store.record(tasks: tasks)
        #expect(store.total == .init())
        clock = clock.addingTimeInterval(1)
        for index in tasks.indices { tasks[index].receivedBytes += 20 }
        store.record(tasks: tasks)
        #expect(store.total.downloaded == 80)
        #expect(store.total.uploaded == 40)
        for kind in TaskKind.allCases {
            #expect(store.byKind[kind.rawValue] == .init(downloaded: 20, uploaded: 10))
        }
        clock = clock.addingTimeInterval(2)
        for index in tasks.indices { tasks[index].receivedBytes += 40 }
        store.record(tasks: tasks)
        #expect(store.total.downloaded == 240)
        #expect(store.total.uploaded == 120)
        #expect(store.days.map(\.traffic.downloaded) == [80, 160])
        #expect(store.recentDays().count == 30)
        #expect(store.recentDays().suffix(2).map(\.traffic.downloaded) == [80, 160])
        tasks[4].deletedAt = nil
        clock = clock.addingTimeInterval(1)
        store.record(tasks: tasks)
        #expect(store.total.downloaded == 240)
    }

    @Test func newTasksAndCounterResetsDoNotProduceNegativeTraffic() {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let store = TransferStatisticsStore(fileURL: root.appending(path: "statistics.json"), now: { clock })
        store.record(tasks: [])
        clock = clock.addingTimeInterval(1)
        var task = task(1)
        store.record(tasks: [task])
        #expect(store.total.downloaded == 100)
        task.receivedBytes = 5
        clock = clock.addingTimeInterval(1)
        store.record(tasks: [task])
        #expect(store.total.downloaded == 100)
        task.receivedBytes = 15
        clock = clock.addingTimeInterval(1)
        store.record(tasks: [task])
        #expect(store.total.downloaded == 110)
    }

    @Test func persistsEveryMinuteAtomicallyWithPrivatePermissionsAndReloads() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "statistics.json")
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let store = TransferStatisticsStore(fileURL: url, now: { clock })
        var task = task(1)
        store.record(tasks: [task])
        clock = clock.addingTimeInterval(59)
        task.receivedBytes += 20
        store.record(tasks: [task])
        #expect(!FileManager.default.fileExists(atPath: url.path))
        clock = clock.addingTimeInterval(1)
        task.receivedBytes += 10
        store.record(tasks: [task])
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let loaded = TransferStatisticsStore(fileURL: url, now: { clock })
        #expect(loaded.total == store.total)
        #expect(loaded.byKind == store.byKind)
        #expect(loaded.days == store.days)
        store.save()
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["statistics.json"])
        #expect(store.issue == nil)
    }

    @Test func corruptMissingAndUnwritableFilesHaveSafeOutcomes() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "statistics.json")
        let clock = Date(timeIntervalSince1970: 1_800_000_000)
        let missing = TransferStatisticsStore(fileURL: url, now: { clock })
        #expect(missing.total == .init())
        #expect(missing.issue == nil)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("invalid json".utf8).write(to: url)
        let corrupt = TransferStatisticsStore(fileURL: url, now: { clock })
        #expect(corrupt.total == .init())
        #expect(corrupt.issue?.contains("损坏") == true)
        corrupt.save()
        #expect(corrupt.issue == nil)
        let invalidDestination = TransferStatisticsStore(fileURL: url.appending(path: "blocked.json"), now: { clock })
        invalidDestination.save()
        #expect(invalidDestination.issue?.contains("无法保存") == true)
    }

    @Test func resetPersistsAndRetainsOnlyPostResetDeltas() {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "statistics.json")
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let store = TransferStatisticsStore(fileURL: url, now: { clock })
        var task = task(1)
        store.record(tasks: [task])
        clock = clock.addingTimeInterval(1)
        task.receivedBytes += 20
        store.record(tasks: [task])
        store.reset()
        #expect(store.total == .init())
        #expect(store.days.isEmpty)
        #expect(store.recentSamples.isEmpty)
        #expect(TransferStatisticsStore(fileURL: url, now: { clock }).total == .init())
        clock = clock.addingTimeInterval(1)
        task.receivedBytes += 7
        store.record(tasks: [task])
        #expect(store.total.downloaded == 7)
    }

    @Test func fixedMemoryCapsAndTenSecondHourlyAveragesShareExistingSamples() {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let store = TransferStatisticsStore(fileURL: root.appending(path: "statistics.json"), now: { clock })
        var task = task(1)
        for index in 0..<10 {
            task.downloadRate = Int64(index * 10)
            task.uploadRate = Int64(index * 2)
            store.record(tasks: [task])
            clock = clock.addingTimeInterval(1)
        }
        #expect(store.hourlySamples.count == 1)
        #expect(store.hourlySamples.first?.download == 45)
        #expect(store.hourlySamples.first?.upload == 9)
        for _ in 0..<4000 {
            store.record(tasks: [task])
            clock = clock.addingTimeInterval(1)
        }
        #expect(store.recentSamples.count <= 601)
        #expect(store.hourlySamples.count <= 361)
        #expect(store.history(.oneHour).count <= 361)
        #expect(store.history(.tenMinutes).count <= 601)
        clock = clock.addingTimeInterval(40 * 86400)
        store.record(tasks: [task])
        #expect(store.recentSamples.count == 1)
        #expect(store.hourlySamples.count == 1)
        #expect(store.days.count == 1)
        #expect(store.recentDays().count == 30)
    }

    @Test func modelUsesTheCoordinatorSamplingHookAndDoesNotInventAnotherTimer() {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let store = TransferStatisticsStore(fileURL: root.appending(path: "statistics.json"), now: { clock })
        let model = AppModel(tasks: [task(1)], preventsSleepWhileDownloading: false)
        model.transferStatistics = store
        model.downloadRateHistory = [model.totalDownloadRate]
        model.tasks[0].receivedBytes += 10
        #expect(store.total.downloaded == 0)
        clock = clock.addingTimeInterval(1)
        model.downloadRateHistory = EngineSnapshotMerger.appendingRate(model.totalDownloadRate, to: model.downloadRateHistory)
        #expect(store.total.downloaded == 10)
        #expect(store.total.uploaded == 10)
        clock = clock.addingTimeInterval(3600)
        model.downloadRateHistory = [model.totalDownloadRate]
        #expect(store.total.uploaded == 60)
    }
}
