import Foundation
import MuleeCore
import Testing
@testable import Mulee

@Suite @MainActor struct ExtractionCoordinatorTests {
    @Test func ignoresIneligibleCompletionsAndRepeatedSnapshots() async throws {
        let context = try ExtractionTestContext()
        var done = try context.task("已解压.zip", status: .completed)
        done.postDownload.extractionState = .succeeded
        var failed = try context.task("未解压.zip", status: .completed)
        failed.postDownload.extractionState = .failed
        context.model.tasks = [
            try context.task("说明.txt", status: .completed),
            try context.task("不开解压.zip", status: .completed, autoExtract: false), done, failed
        ]
        context.coordinator.start()
        context.coordinator.tasksDidChange()
        await Task.yield()
        #expect(await context.extractor.calls.isEmpty)
        try await context.clean()
    }

    @Test func globalSwitchOffDoesNotTriggerEvenWhenLaterEnabled() async throws {
        let context = try ExtractionTestContext()
        context.settings.autoExtract = false
        context.model.tasks = [try context.task(status: .completed)]
        context.coordinator.start()
        context.settings.autoExtract = true
        context.coordinator.tasksDidChange()
        await Task.yield()
        #expect(await context.extractor.calls.isEmpty)
        try await context.clean()
    }

    @Test func onlyCompletionTriggersAndProgressSurvivesEngineRefresh() async throws {
        let context = try ExtractionTestContext(suspends: true)
        context.model.tasks = [try context.task()]
        context.coordinator.start()
        await Task.yield()
        #expect(await context.extractor.calls.isEmpty)

        context.model.tasks[0].status = .completed
        try await context.waitUntil { context.model.tasks[0].postDownload.extractProgress == 0.25 }
        #expect(context.model.tasks[0].status == .extracting)
        // 模拟 aria2 下一帧再次写回 completed。
        context.model.tasks[0].status = .completed
        #expect(context.model.tasks[0].status == .extracting)
        await context.extractor.release()
        try await context.waitUntil { context.model.tasks[0].postDownload.extractionState == .succeeded }

        #expect(context.model.tasks[0].status == .completed)
        #expect(context.model.tasks[0].postDownload.extractProgress == 1)
        #expect(context.model.tasks[0].postDownload.filenameEncoding == "UTF-8")
        #expect(context.model.tasks[0].postDownload.extractedItems?.count == 1)
        context.coordinator.tasksDidChange()
        #expect(await context.extractor.calls.count == 1)
        try await context.clean()
    }

    @Test func waitsForAllVolumesAndExtractsGroupOnlyOnce() async throws {
        let context = try ExtractionTestContext()
        context.model.tasks = [
            try context.task("星雲.7z.001", status: .completed),
            try context.task("星雲.7z.002", createFile: false)
        ]
        context.coordinator.start()
        try await context.waitUntil { context.model.tasks[0].postDownload.extractionState == .waitingForVolumes }
        #expect(await context.extractor.calls.isEmpty)
        #expect(context.model.tasks[0].status == .completed)
        try Data("末卷".utf8).write(to: context.root.appendingPathComponent("星雲.7z.002"))
        context.model.tasks[1].status = .completed
        try await context.waitUntil { context.model.tasks.allSatisfy { $0.postDownload.extractionState == .succeeded } }

        let call = try #require(await context.extractor.calls.first)
        #expect(call.archive.lastPathComponent == "星雲.7z.001")
        #expect(call.options.expectedVolumeNames == ["星雲.7z.001", "星雲.7z.002"])
        #expect(await context.extractor.calls.count == 1)
        try await context.clean()
    }

    @Test func missingFirstVolumeWaitsAndOtherDirectoryIsIndependent() async throws {
        let context = try ExtractionTestContext()
        context.model.tasks = [try context.task("资料.part2.rar", status: .completed)]
        context.coordinator.start()
        try await context.waitUntil { context.model.tasks[0].postDownload.extractionState == .waitingForVolumes }
        #expect(await context.extractor.calls.isEmpty)
        let other = context.root.appendingPathComponent("其他目录")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        var unrelated = try context.task("资料.part1.rar", createFile: false)
        unrelated.savePath = other.appendingPathComponent(unrelated.name)
        context.model.tasks.append(unrelated)
        await Task.yield()
        #expect(await context.extractor.calls.isEmpty)
        try await context.clean()
    }

    @Test func serialQueueDoesNotStartSecondArchiveUntilFirstFinishes() async throws {
        let context = try ExtractionTestContext(suspends: true)
        context.model.tasks = [try context.task("一.zip", status: .completed), try context.task("二.zip", status: .completed)]
        context.coordinator.start()
        try await context.waitUntil { await context.extractor.calls.count == 1 }
        #expect(context.model.tasks[0].status == .extracting)
        #expect(context.model.tasks[1].status == .completed)
        #expect(context.model.tasks[1].postDownload.extractionState == .queued)
        await context.extractor.release()
        try await context.waitUntil { await context.extractor.calls.count == 2 }
        #expect(context.model.tasks[0].postDownload.extractionState == .succeeded)
        #expect(context.model.tasks[1].status == .extracting)
        await context.extractor.release()
        try await context.waitUntil { context.model.tasks[1].postDownload.extractionState == .succeeded }
        #expect(await context.extractor.maximumActive == 1)
        try await context.clean()
    }

    @Test func failureKeepsDownloadCompletedAndOriginalUntouched() async throws {
        let context = try ExtractionTestContext(outcome: ExtractionOutcome(status: .failed, failure: .wrongPasswords))
        context.settings.originalAction = .delete
        let task = try context.task(status: .completed)
        let path = try #require(task.savePath)
        let original = try Data(contentsOf: path)
        context.model.tasks = [task]
        context.coordinator.start()
        try await context.waitUntil { context.model.tasks[0].postDownload.extractionState == .failed }

        #expect(context.model.tasks[0].status == .completed)
        #expect(context.model.tasks[0].errorMessage == nil)
        #expect(context.model.tasks[0].postDownload.extractionFailure == "密码都不对")
        #expect(try Data(contentsOf: path) == original)
        try await context.clean()
    }

    @Test func cancellationFinishesBeforeStopReturnsAndDoesNotRunQueuedWork() async throws {
        let context = try ExtractionTestContext(suspends: true)
        context.model.tasks = [try context.task("一.zip", status: .completed), try context.task("二.zip", status: .completed)]
        context.coordinator.start()
        try await context.waitUntil { await context.extractor.calls.count == 1 }
        await context.coordinator.stop()

        #expect(context.model.tasks[0].status == .completed)
        #expect(context.model.tasks[0].postDownload.extractionState == .cancelled)
        #expect(await context.extractor.calls.count == 1)
        try await context.clean()
    }

    @Test(arguments: [SettingsModel.FilenameEncoding.auto, .gbk, .big5, .shiftJIS])
    func forwardsSettingsAndSourceRules(_ encoding: SettingsModel.FilenameEncoding) async throws {
        let context = try ExtractionTestContext()
        context.settings.filenameEncoding = encoding
        context.settings.originalAction = .delete
        context.settings.extractNested = true
        let rule = UnzipRule(matchKind: .sourceSite, pattern: "files.example.com", keychainItemID: "test-rule", maskedLength: 4, hitCount: 0)
        context.model.unzipRules = [rule]
        context.model.tasks = [try context.task(status: .completed)]
        context.coordinator.start()
        try await context.waitUntil { context.model.tasks[0].postDownload.extractionState == .succeeded }
        let call = try #require(await context.extractor.calls.first)
        let expected: ArchiveFilenameEncoding = switch encoding {
        case .auto: .automatic
        case .gbk: .gbk
        case .big5: .big5
        case .shiftJIS: .shiftJIS
        }
        #expect(call.options.encoding == expected)
        #expect(call.options.postAction == .delete)
        #expect(call.options.recursivelyExtract)
        #expect(call.rules == [rule])
        #expect(call.sourceURL?.host == "files.example.com")
        #expect(context.model.tasks[0].postDownload.matchedRuleName == rule.pattern)
        try await context.clean()
    }

    @Test func extractorWaitingResultDoesNotSpinOnIdenticalSnapshots() async throws {
        let context = try ExtractionTestContext(outcome: ExtractionOutcome(status: .waitingForVolumes, failure: .missingVolumes([])))
        context.model.tasks = [try context.task("资料.7z.001", status: .completed)]
        context.coordinator.start()
        try await context.waitUntil { context.model.tasks[0].postDownload.extractionState == .waitingForVolumes }
        for _ in 0..<5 {
            context.coordinator.tasksDidChange()
            await Task.yield()
        }
        #expect(await context.extractor.calls.count == 1)
        #expect(context.model.tasks[0].status == .completed)
        try await context.clean()
    }
}
