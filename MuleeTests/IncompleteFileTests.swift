import Foundation
import MuleeCore
import Testing
@testable import Mulee

@Suite @MainActor struct IncompleteFileTests {
    @Test func settingDefaultsToEnabledAndPersists() throws {
        let name = "IncompleteFileTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsModel(defaults: defaults)
        #expect(settings.markIncomplete)
        settings.markIncomplete = false
        #expect(!SettingsModel(defaults: defaults).markIncomplete)
        #expect(defaults.object(forKey: "download.markIncomplete") as? Bool == false)
    }

    @Test func extractionWaitsForMoveAndVerification() throws {
        var task = MockData.longTailTask
        task.status = .completed
        task.savePath = URL(filePath: "/tmp/downloads/.mulee-incomplete/task/sample.zip")
        #expect(!ExtractionCoordinator.isReadyForExtraction(task))
        task.savePath = URL(filePath: "/tmp/downloads/sample.zip.mulee")
        #expect(!ExtractionCoordinator.isReadyForExtraction(task))
        task.savePath = URL(filePath: "/tmp/downloads/sample.zip")
        #expect(ExtractionCoordinator.isReadyForExtraction(task))
        let checksum = try #require(DownloadChecksum.parse(String(repeating: "a", count: 64)))
        task.checksum = checksum
        #expect(!ExtractionCoordinator.isReadyForExtraction(task))
        task.checksumVerification = ChecksumVerification(expected: checksum, actual: String(repeating: "b", count: 64))
        #expect(!ExtractionCoordinator.isReadyForExtraction(task))
        task.checksumVerification = ChecksumVerification(expected: checksum, actual: checksum.digest)
        #expect(ExtractionCoordinator.isReadyForExtraction(task))
        task.status = .downloading
        #expect(!ExtractionCoordinator.isReadyForExtraction(task))
    }

    @Test func automaticExtractionStartsOnlyAfterFileMoves() async throws {
        let context = try ExtractionTestContext()
        var task = try context.task(status: .completed)
        let completed = try #require(task.savePath)
        var transfer = IncompleteHTTPTransfer(taskID: task.id, destination: context.root)
        try transfer.prepare()
        let staged = transfer.directory.appendingPathComponent(completed.lastPathComponent)
        try FileManager.default.moveItem(at: completed, to: staged)
        task.savePath = staged
        context.model.tasks = [task]
        context.coordinator.start()
        await Task.yield()
        #expect(await context.extractor.calls.isEmpty)
        try transfer.planMove(from: staged)
        context.model.tasks[0].savePath = try transfer.finishMove(from: staged)
        try await context.waitUntil { await context.extractor.calls.count == 1 }
        try await context.clean()
    }
}
