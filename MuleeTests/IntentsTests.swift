import AppIntents
import Foundation
import MuleeCore
import Testing
@testable import Mulee

@Suite @MainActor struct IntentsTests {
    @Test func validatesRequiredLinkAndOptionalAbsoluteDirectory() throws {
        for link in ["", "  ", "not a link", "file:///tmp/file", "https://example.com/a\nhttps://example.com/b"] {
            #expect(throws: MuleeIntentActions.ValidationError.self) {
                try MuleeIntentActions.validate(link: link, directory: nil)
            }
        }
        #expect(throws: MuleeIntentActions.ValidationError.self) {
            try MuleeIntentActions.validate(link: "https://example.com/file", directory: "relative/folder")
        }
        #expect(try MuleeIntentActions.validate(link: "https://example.com/file", directory: nil).directory == nil)
        #expect(try MuleeIntentActions.validate(link: "magnet:?xt=urn:btih:0123456789012345678901234567890123456789", directory: "/tmp/chosen").directory?.path == "/tmp/chosen")
    }

    @Test func prefillConsumesDirectoryWithoutStartingAnyDownload() throws {
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        let actions = MuleeIntentActions(model: model)
        try actions.prefill(link: "https://example.com/file.zip", directory: "/tmp/chosen")
        #expect(model.tasks.isEmpty)
        #expect(model.isShowingNewTask)
        #expect(model.pendingNewTaskText == "https://example.com/file.zip")
        let draft = NewTaskModel(saveDirectory: URL(filePath: "/tmp/default"))
        draft.consumePendingText(from: model)
        #expect(draft.saveDirectory.path == "/tmp/chosen")
        #expect(draft.linkCount == 1)
        #expect(model.pendingNewTaskDirectory == nil)
        #expect(model.pendingNewTaskText.isEmpty)
        #expect(model.tasks.isEmpty)
    }

    @Test func intentsPerformThroughInjectedActions() async throws {
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        let actions = MuleeIntentActions(model: model)
        var intent = NewMuleeDownloadIntent()
        intent.actions = actions
        intent.link = "https://example.com/download"
        intent.directory = "/tmp/intent"
        _ = try await intent.perform()
        #expect(model.tasks.isEmpty)
        #expect(model.pendingNewTaskDirectory?.path == "/tmp/intent")
        #expect(model.isShowingNewTask)
        var task = DownloadTask(link: LinkParser.parse("https://example.com/file").first!, autoExtract: false)
        task.status = .downloading
        model.tasks = [task]
        let pause = PauseMuleeDownloadsIntent()
        pause.actions = actions
        _ = try await pause.perform()
        #expect(model.tasks[0].status == .paused)
        let resume = ResumeMuleeDownloadsIntent()
        resume.actions = actions
        _ = try await resume.perform()
        #expect(model.tasks[0].status == .downloading)
        let status = MuleeDownloadStatusIntent()
        status.actions = actions
        _ = try await status.perform()
    }

    @Test func statusExcludesTrashAndFindsMostRecentCompletion() throws {
        var tasks = (0..<3).map { index in
            DownloadTask(link: LinkParser.parse("https://example.com/file\(index)").first!, autoExtract: false)
        }
        tasks[0].status = .downloading
        tasks[0].downloadRate = 120
        tasks[0].uploadRate = 20
        tasks[1].status = .completed
        tasks[1].completedAt = Date(timeIntervalSince1970: 100)
        tasks[1].name = "Completed sample"
        tasks[2].status = .downloading
        tasks[2].downloadRate = 999
        tasks[2].completedAt = Date(timeIntervalSince1970: 200)
        tasks[2].deletedAt = .now
        let model = AppModel(tasks: tasks, preventsSleepWhileDownloading: false)
        let status = MuleeIntentActions(model: model).status()
        #expect(status.downloadingCount == 1)
        #expect(status.downloadRate == 120)
        #expect(status.uploadRate == 20)
        #expect(status.latestCompletedName == "Completed sample")
        #expect(status.summary.contains("Completed sample"))
    }

    @Test func muleeAddURLOnlyPrefillsAndShortcutsHaveAllFourLocales() throws {
        let defaults = try TemporaryDefaults(prefix: "IntentURL-")
        defer { defaults.clean() }
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        let router = OpenURLRouter(model: model, settings: SettingsModel(defaults: defaults.defaults))
        let url = try #require(URL(string: "mulee://add?url=https%3A%2F%2Fexample.com%2Ffile"))
        #expect(router.open([url]))
        #expect(model.tasks.isEmpty)
        #expect(model.pendingNewTaskText == "https://example.com/file")
        #expect(model.isShowingNewTask)
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appending(path: "Mulee/Intents/AppShortcuts.xcstrings"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(object["strings"] as? [String: [String: Any]])
        #expect(strings.count == 4)
        for (key, value) in strings {
            #expect(key.contains("${applicationName}"))
            let locales = try #require(value["localizations"] as? [String: [String: Any]])
            for locale in ["zh-Hans", "en", "zh-Hant", "ja"] {
                let unit = try #require(locales[locale]?["stringUnit"] as? [String: String])
                #expect(unit["state"] == "translated")
                #expect(unit["value"]?.contains("${applicationName}") == true)
            }
        }
        #expect(MuleeAppShortcuts.appShortcuts.count == 4)
    }
}
