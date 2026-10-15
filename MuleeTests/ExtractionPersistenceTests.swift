import Foundation
import MuleeCore
import Testing
@testable import Mulee

@Suite @MainActor struct ExtractionPersistenceTests {
    @Test func readsOldTasksJSONWithoutExtractionFields() async throws {
        let context = try ExtractionTestContext()
        var oldTask = try context.task(status: .completed)
        oldTask.postDownload.matchedRuleName = "旧规则"
        oldTask.postDownload.filenameEncoding = "Big5"
        let taskData = try JSONEncoder().encode(oldTask)
        let object = try #require(JSONSerialization.jsonObject(with: taskData) as? [String: Any])
        // 旧文档只包含原有四个 postDownload 字段。
        var oldObject = object
        oldObject["postDownload"] = ["autoExtract": true, "matchedRuleName": "旧规则", "filenameEncoding": "Big5", "extractProgress": 0.5]
        let store = TaskHistoryStore(directory: context.root)
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "tasks": [oldObject]])
        try data.write(to: store.fileURL)

        let loaded = store.load()
        #expect(loaded.issue == nil)
        let task = try #require(loaded.tasks.first)
        #expect(task.id == oldTask.id)
        #expect(task.postDownload.autoExtract)
        #expect(task.postDownload.matchedRuleName == "旧规则")
        #expect(task.postDownload.filenameEncoding == "Big5")
        #expect(task.postDownload.extractionState == nil)
        #expect(task.postDownload.extractedItems == nil)
        #expect(task.postDownload.extractionFailure == nil)
        try await context.clean()
    }

    @Test func successfulExtractionSurvivesHistoryAndRestartWithoutRepeating() async throws {
        let context = try ExtractionTestContext()
        let store = TaskHistoryStore(directory: context.root)
        context.model.loadTaskHistory(from: store)
        context.model.tasks = [try context.task(status: .completed)]
        context.coordinator.start()
        try await context.waitUntil { context.model.tasks[0].postDownload.extractionState == .succeeded }
        await context.coordinator.stop()
        let restoredModel = AppModel(tasks: [], unzipRules: [], preventsSleepWhileDownloading: false)
        restoredModel.loadTaskHistory(from: TaskHistoryStore(directory: context.root))
        let fake = ExtractionFakeExtractor()
        let coordinator = ExtractionCoordinator(model: restoredModel, settings: context.settings, extractor: fake)
        coordinator.start()
        await Task.yield()

        #expect(await fake.calls.isEmpty)
        #expect(restoredModel.tasks[0].status == .completed)
        #expect(restoredModel.tasks[0].postDownload.extractionState == .succeeded)
        #expect(restoredModel.tasks[0].postDownload.extractedItems == context.model.tasks[0].postDownload.extractedItems)
        #expect(restoredModel.tasks[0].postDownload.filenameEncoding == "UTF-8")
        await coordinator.stop()
        try await context.clean()
    }

    @Test func interruptedExtractionRemainsDownloadCompleteOnRestart() async throws {
        let context = try ExtractionTestContext()
        var task = try context.task(status: .extracting)
        task.postDownload.extractionState = .extracting
        context.model.tasks = [task]
        context.coordinator.start()
        await Task.yield()

        #expect(context.model.tasks[0].status == .completed)
        #expect(context.model.tasks[0].postDownload.extractionState == .cancelled)
        #expect(await context.extractor.calls.isEmpty)
        try await context.clean()
    }

    @Test func rulesPersistWithoutPasswordsAndDeletionRemovesStoredSecret() async throws {
        let context = try ExtractionTestContext()
        let passwords = ExtractionMemoryPasswords()
        context.model.extractionPasswords = passwords
        context.model.loadUnzipRules(from: UnzipRuleStore(defaults: context.defaults))
        try await context.model.addUnzipRule(kind: .filenamePrefix, pattern: "星雲*", password: "local-secret-9876")
        let rule = try #require(context.model.unzipRules.first)
        let itemID = try #require(rule.keychainItemID)
        #expect(try await passwords.password(for: itemID) == "local-secret-9876")
        let persisted = try #require(context.defaults.data(forKey: "unzip.rules"))
        #expect(!String(decoding: persisted, as: UTF8.self).contains("local-secret-9876"))
        let restored = AppModel(tasks: [], unzipRules: [], preventsSleepWhileDownloading: false)
        restored.extractionPasswords = passwords
        restored.loadUnzipRules(from: UnzipRuleStore(defaults: context.defaults))
        #expect(restored.unzipRules == [rule])

        try await restored.removeUnzipRule(rule.id)
        #expect(try await passwords.password(for: itemID) == nil)
        #expect(try UnzipRuleStore(defaults: context.defaults).load().isEmpty)
        try await context.clean()
    }

    @Test func passwordBookUsesOnlyPasswordStoreAndEnablesFallback() async throws {
        let context = try ExtractionTestContext()
        let passwords = ExtractionMemoryPasswords()
        context.model.extractionPasswords = passwords
        context.model.loadUnzipRules(from: UnzipRuleStore(defaults: context.defaults))
        try await context.model.saveExtractionPasswordBook(["book-secret-one", "book-secret-two"])
        #expect(try await passwords.passwordBook() == ["book-secret-one", "book-secret-two"])
        #expect(context.model.unzipRules.count == 1)
        #expect(context.model.unzipRules[0].matchKind == .passwordBook)
        let stored = try #require(context.defaults.data(forKey: "unzip.rules"))
        #expect(!String(decoding: stored, as: UTF8.self).contains("book-secret"))
        #expect(UnzipRuleMatcher.match(rules: context.model.unzipRules, filename: "普通.7z", sourceURL: nil).sources == [.passwordBook])
        try await context.model.saveExtractionPasswordBook([])
        #expect(try await passwords.passwordBook().isEmpty)
        try await context.clean()
    }

    @Test func keychainFailureDoesNotAddOrDeleteRule() async throws {
        let context = try ExtractionTestContext()
        let passwords = ExtractionMemoryPasswords()
        context.model.extractionPasswords = passwords
        try await context.model.addUnzipRule(kind: .sourceSite, pattern: "example.com", password: "test")
        let rule = try #require(context.model.unzipRules.first)
        await passwords.failWrites()

        await #expect(throws: ExtractionFailure.passwordStorage) {
            try await context.model.addUnzipRule(kind: .filenamePrefix, pattern: "another", password: "test")
        }
        await #expect(throws: ExtractionFailure.passwordStorage) {
            try await context.model.removeUnzipRule(rule.id)
        }
        #expect(context.model.unzipRules == [rule])
        try await context.clean()
    }
}
