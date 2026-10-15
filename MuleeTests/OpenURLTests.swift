import Foundation
import MuleeCore
import Testing
@testable import Mulee

@Suite @MainActor struct OpenURLTests {
    private let magnet = "magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c"
    private let ed2k = "ed2k://|file|Sintel.zip|1024|9F3A0C5E7D21B84A6C0E93F15B71DC21|/"

    private func request(_ values: [String], host: String = "add", text: String? = nil) throws -> URL {
        var components = URLComponents()
        components.scheme = "mulee"
        components.host = host
        components.queryItems = values.map { URLQueryItem(name: "url", value: $0) }
        components.queryItems?.append(URLQueryItem(name: "referrer", value: "https://pages.example.org/资料?q=a&b=c"))
        if let text { components.queryItems?.append(URLQueryItem(name: "text", value: text)) }
        return try #require(components.url)
    }

    @Test func parsesMultipleEncodedURLsAndReferrer() throws {
        let url = try request([magnet, ed2k, "https://example.org/a.zip?q=1&b=%E4%B8%AD"])
        let result = try #require(OpenURLRequest.parse(url, detectPagePassword: true))
        #expect(result.links.count == 3)
        #expect(result.links[0].original == magnet)
        #expect(result.sourcePageURL?.host == "pages.example.org")
        #expect(result.links[2].original.contains("&b="))
    }

    @Test func supportsURLSearchParamsSpaceEncoding() throws {
        let url = try #require(URL(string: "mulee://add?url=https%3A%2F%2Fexample.org%2Fa.zip&text=password%3A+abc123"))
        #expect(OpenURLRequest.parse(url, detectPagePassword: true)?.password == "abc123")
    }

    @Test func enforcesCountAndByteLimits() throws {
        #expect(OpenURLRequest.parse(try request(Array(repeating: magnet, count: 200)), detectPagePassword: true)?.links.count == 200)
        #expect(OpenURLRequest.parse(try request(Array(repeating: magnet, count: 201)), detectPagePassword: true) == nil)
        #expect(OpenURLRequest.parse(try request([magnet], text: String(repeating: "a", count: OpenURLRequest.maximumBytes)), detectPagePassword: true) == nil)
        let packed = (0..<201).map { "https://example.org/\($0).zip" }.joined(separator: "\n")
        #expect(OpenURLRequest.parse(try request([packed]), detectPagePassword: true) == nil)
    }

    @Test func rejectsLocalInputsAndUnknownCommands() throws {
        let localThunder = "thunder://" + Data("AAfile:///tmp/private.torrentZZ".utf8).base64EncodedString()
        for value in ["file:///tmp/private.torrent", "/tmp/private.torrent", "~/private.torrent", localThunder] {
            #expect(OpenURLRequest.parse(try request([value]), detectPagePassword: true) == nil)
        }
        #expect(OpenURLRequest.parse(try request([magnet], host: "start"), detectPagePassword: true) == nil)
        let embedded = "https://example.org/a.zip\nfile:///tmp/private.torrent"
        #expect(OpenURLRequest.parse(try request([embedded]), detectPagePassword: true) == nil)
    }

    @Test(arguments: ["解压密码：abc123", "密码: abc123", "password: abc123", "PASSWORD：abc123"])
    func detectsPasswordsOnlyWhenEnabled(_ text: String) {
        #expect(OpenURLRequest.pagePassword(in: text, enabled: true) == "abc123")
        #expect(OpenURLRequest.pagePassword(in: text, enabled: false) == nil)
    }

    @Test func systemSchemesMergeIntoOneDraftWithoutStarting() throws {
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        let settings = SettingsModel()
        let router = OpenURLRouter(model: model, settings: settings)
        let thunder = "thunder://" + Data("AAhttps://example.org/Sintel.zipZZ".utf8).base64EncodedString()
        #expect(router.open(try [magnet, ed2k, thunder].map { try #require(URL(dataRepresentation: Data($0.utf8), relativeTo: nil)) }))
        #expect(router.open([try request(["https://example.org/Ubuntu.zip"], text: "密码：secret")]))
        #expect(model.isShowingNewTask)
        #expect(model.tasks.isEmpty)
        let draft = NewTaskModel(inputText: "https://example.org/first.zip")
        draft.consumePendingText(from: model)
        #expect(draft.linkCount == 5)
        #expect(model.pendingNewTaskText.isEmpty)
        #expect(router.open([try request(["https://example.org/last.zip"])]))
        draft.consumePendingText(from: model)
        #expect(draft.linkCount == 6)
        draft.createTasks(in: model)
        let task = try #require(model.tasks.first { $0.sourceLink.contains("Ubuntu") })
        #expect(task.sourcePageURL?.host == "pages.example.org")
        #expect(model.pagePasswords[task.id] == "secret")
        #expect(!String(decoding: try JSONEncoder().encode(model.tasks), as: UTF8.self).contains("secret"))
    }

    @Test func disabledSettingDoesNotAttachPagePassword() throws {
        let context = try ExtractionTestContext()
        context.settings.detectPagePassword = false
        let router = OpenURLRouter(model: context.model, settings: context.settings)
        #expect(router.open([try request(["https://example.org/a.zip"], text: "密码：secret")]))
        #expect(context.model.pendingNewTaskContexts.values.allSatisfy { $0.password == nil })
        context.defaults.removePersistentDomain(forName: context.suiteName)
        try FileManager.default.removeItem(at: context.root)
    }

    @Test func confirmedTasksKeepContextWithRealCoordinator() async throws {
        let context = try ExtractionTestContext()
        let engine = FakeEngine()
        let coordinator = DownloadCoordinator(model: context.model, engines: [engine])
        await coordinator.start(options: EngineOptions(downloadDirectory: context.root))
        let router = OpenURLRouter(model: context.model, settings: context.settings)
        #expect(router.open([try request(["https://example.org/first.zip", "https://example.org/second.zip"], text: "密码：secret")]))
        let draft = NewTaskModel(saveDirectory: context.root)
        draft.consumePendingText(from: context.model)
        #expect(await engine.addedLinks.isEmpty)
        draft.createTasks(in: context.model)
        try await context.waitUntil { context.model.tasks.count == 2 && context.model.tasks.allSatisfy { $0.sourcePageURL != nil } }
        #expect(context.model.tasks.map(\.name) == ["first.zip", "second.zip"])
        #expect(context.model.tasks.allSatisfy { context.model.pagePasswords[$0.id] == "secret" })
        await coordinator.stop()
        try await context.clean()
    }

    @Test func routesLocalTorrentWithoutReadingItUntilDraftOpens() throws {
        let file = URL(filePath: "/tmp/Ubuntu.torrent")
        let result = try #require(OpenURLRequest.parse(file, detectPagePassword: false))
        #expect(result.links == [.torrentFile(url: file, original: file.absoluteString)])
    }

    @Test func oldTasksDecodeAndSourcePageRoundTrips() throws {
        let url = try #require(URL(string: "https://example.org/a.zip"))
        let original = DownloadTask(link: .http(url: url, decodedFromThunder: false, original: "https://example.org/a.zip"), autoExtract: true)
        let data = try JSONEncoder().encode(original)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "sourcePageURL")
        let oldData = try JSONSerialization.data(withJSONObject: json)
        var task = try JSONDecoder().decode(DownloadTask.self, from: oldData)
        #expect(task.sourcePageURL == nil)
        task.sourcePageURL = URL(string: "https://pages.example.org/download")
        let decoded = try JSONDecoder().decode(DownloadTask.self, from: JSONEncoder().encode(task))
        #expect(decoded.sourcePageURL == task.sourcePageURL)
    }

    @Test func extractionPrefersSourcePageAndRemovesTemporaryPassword() async throws {
        let context = try ExtractionTestContext()
        var task = try context.task(status: .completed)
        task.sourcePageURL = URL(string: "https://pages.example.org/download")
        context.model.tasks = [task]
        context.model.pagePasswords[task.id] = "secret"
        context.model.unzipRules = [UnzipRule(matchKind: .sourceSite, pattern: "pages.example.org", keychainItemID: nil, maskedLength: 0, hitCount: 0)]
        context.coordinator.start()
        try await context.waitUntil { context.model.tasks[0].postDownload.extractionState == .succeeded }
        let call = try #require(await context.extractor.calls.first)
        #expect(call.sourceURL == task.sourcePageURL)
        #expect(context.model.tasks[0].postDownload.matchedRuleName == "pages.example.org")
        #expect(call.rules == context.model.unzipRules)
        #expect(call.options.pagePasswords == ["secret"])
        let passwords = try #require(context.model.extractionPasswords as? ExtractionMemoryPasswords)
        #expect(await passwords.passwords.isEmpty)
        try await context.clean()
    }
}
