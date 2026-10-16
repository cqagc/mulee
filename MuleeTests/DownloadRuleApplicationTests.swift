import Foundation
import MuleeCore
import Testing
@testable import Mulee

@MainActor
struct DownloadRuleApplicationTests {
    @Test(arguments: TaskKind.allCases)
    func ruleDirectoryAppliesToEveryKindAndUserAgentOnlyToHTTP(kind: TaskKind) async throws {
        let defaults = try TemporaryDefaults(prefix: "DownloadRules-")
        defer { defaults.clean() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = SettingsModel(defaults: defaults.defaults)
        settings.downloadRules = [
            DownloadRule(name: "first", sourceSite: "*.example.test", taskKind: kind,
                         subdirectory: "site/files", userAgent: "RuleAgent", httpThreads: 4, speedLimitBytes: 1024),
            DownloadRule(name: "second", subdirectory: "unused")
        ]
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        model.downloadSettings = settings
        let engine = FakeEngine(kind: kind)
        let coordinator = DownloadCoordinator(model: model, engines: [engine])
        await coordinator.start(options: EngineOptions(downloadDirectory: root))
        let link = link(for: kind)
        let context = DownloadRequestContext(referer: URL(string: "https://page.example.test/article"), userAgent: "OriginalAgent")
        await coordinator.add(links: [link], autoExtract: false, requestContexts: [link: context])
        await coordinator.stop()

        #expect(await engine.directories == [root.appendingPathComponent("site/files", isDirectory: true)])
        let task = try #require(model.tasks.first)
        #expect(task.requestContext?.userAgent == (kind == .http ? "RuleAgent" : "OriginalAgent"))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("site/files").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("unused").path) == false)
    }

    @Test(arguments: TaskKind.allCases)
    func categoryFoldersAreOptIn(kind: TaskKind) async throws {
        let defaults = try TemporaryDefaults(prefix: "DownloadCategories-")
        defer { defaults.clean() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = SettingsModel(defaults: defaults.defaults)
        #expect(settings.sortIntoFolders == false)
        #expect(settings.downloadRules.isEmpty)
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        model.downloadSettings = settings
        let engine = FakeEngine(kind: kind)
        let coordinator = DownloadCoordinator(model: model, engines: [engine])
        await coordinator.start(options: EngineOptions(downloadDirectory: root))
        let link = link(for: kind)
        await coordinator.add(links: [link], autoExtract: false)
        settings.sortIntoFolders = true
        await coordinator.add(links: [link], autoExtract: false)
        await coordinator.stop()

        let category: DownloadCategory = kind == .video ? .video : .archive
        #expect(await engine.directories == [root, root.appendingPathComponent(category.folderName, isDirectory: true)])
        let reloaded = SettingsModel(defaults: defaults.defaults)
        #expect(reloaded.sortIntoFolders)
    }

    @Test func rulesPersistInListOrder() throws {
        let defaults = try TemporaryDefaults(prefix: "DownloadRulePersistence-")
        defer { defaults.clean() }
        let settings = SettingsModel(defaults: defaults.defaults)
        let rules = [DownloadRule(name: "first", subdirectory: "one"), DownloadRule(name: "second", subdirectory: "two")]
        settings.downloadRules = rules
        #expect(SettingsModel(defaults: defaults.defaults).downloadRules == rules)
    }

    private func link(for kind: TaskKind) -> ParsedLink {
        let url = URL(string: "https://files.other.test/archive.zip")!
        switch kind {
        case .http:
            return .http(url: url, decodedFromThunder: false, original: url.absoluteString)
        case .bittorrent:
            return .magnet(infoHash: String(repeating: "a", count: 40), displayName: "archive.zip", original: "magnet:?xt=urn:btih:" + String(repeating: "a", count: 40))
        case .ed2k:
            return .ed2k(fileName: "archive.zip", size: 100, hash: String(repeating: "A", count: 32), original: "ed2k://fixture")
        case .video:
            return .video(url: url, site: .other, original: url.absoluteString)
        }
    }
}
