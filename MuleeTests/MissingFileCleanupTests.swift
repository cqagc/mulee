import Foundation
import MuleeCore
import Testing
@testable import Mulee

@Suite @MainActor struct MissingFileCleanupTests {
    @Test func candidatesOnlyIncludeMissingCompletedRecords() {
        var missing = MockData.tasks[0]
        missing.status = .completed
        missing.completedAt = .now
        missing.fileMissing = true
        missing.savePath = URL(filePath: "/tmp/missing.zip")

        var present = MockData.tasks[1]
        present.status = .completed
        present.completedAt = .now

        var active = MockData.tasks[2]
        active.status = .downloading
        active.fileMissing = true

        let model = AppModel(tasks: [missing, present, active], preventsSleepWhileDownloading: false)
        #expect(model.missingFileRecordCandidates(in: [missing.id, present.id, active.id]) == [missing.id])
        #expect(model.missingFileRecordCandidates(in: [present.id]).isEmpty)
    }

    @Test func cleanupMovesRecordsToTrashWithoutRemovingPayloadOrOtherTasks() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "Mulee-missing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var missing = MockData.tasks[0]
        missing.status = .completed
        missing.completedAt = .now
        missing.fileMissing = true
        missing.savePath = directory.appending(path: "removed.bin")
        let present = MockData.tasks[1]
        let model = AppModel(tasks: [missing, present], preventsSleepWhileDownloading: false)

        let count = await model.trashMissingFileRecords([missing.id, present.id])
        #expect(count == 1)
        #expect(model.tasks.first { $0.id == missing.id }?.deletedAt != nil)
        #expect(model.tasks.first { $0.id == present.id }?.deletedAt == nil)
    }

    @Test func cleanupRechecksThePathAndSkipsSeeding() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "Mulee-missing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var stale = MockData.tasks[0]
        stale.status = .completed
        stale.completedAt = .now
        stale.fileMissing = true
        stale.savePath = directory.appending(path: "present.bin")
        try Data([1]).write(to: stale.savePath!)
        var seeding = MockData.tasks[1]
        seeding.status = .seeding
        seeding.completedAt = .now
        seeding.fileMissing = true
        seeding.savePath = directory.appending(path: "seed.bin")
        let model = AppModel(tasks: [stale, seeding], preventsSleepWhileDownloading: false)
        #expect(await model.trashMissingFileRecords([stale.id, seeding.id]) == 0)
        #expect(model.tasks.allSatisfy { $0.deletedAt == nil })
    }

    @Test func skipsDisconnectedVolumeAndPendingExtraction() async {
        var offline = MockData.tasks[0]
        offline.status = .completed
        offline.fileMissing = true
        offline.savePath = URL(filePath: "/Volumes/unmounted-\(UUID().uuidString)/result.zip")
        var pending = MockData.tasks[1]
        pending.status = .completed
        pending.fileMissing = true
        pending.postDownload.extractionState = .waitingForVolumes
        pending.savePath = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let model = AppModel(tasks: [offline, pending], preventsSleepWhileDownloading: false)
        let ids: Set<UUID> = [offline.id, pending.id]
        #expect(model.confirmedMissingFileRecords(in: model.missingFileRecordCandidates(in: ids)).isEmpty)
        #expect(await model.trashMissingFileRecords(ids) == 0)
        #expect(model.tasks.allSatisfy { $0.deletedAt == nil })
    }
}
