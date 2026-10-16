import Foundation
import MuleeCore
import Testing
@testable import Mulee

@Suite @MainActor struct ExtensionHandoffTests {
    private let token = String(repeating: "a1", count: 16)
    private let downloadURL = URL(string: "https://example.org/archive.zip")!

    private func payload(token: String? = nil, url: URL? = nil, cookie: String = "session=synthetic-private") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "type": "downloadCookies", "token": token ?? self.token,
            "url": (url ?? downloadURL).absoluteString, "cookie": cookie
        ])
    }

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ExtensionHandoff-\(UUID())", isDirectory: true)
    }

    private func entry(_ url: URL, token: String? = nil, filename: String? = nil) throws -> URL {
        var components = URLComponents(string: "mulee://add")!
        components.queryItems = [
            URLQueryItem(name: "url", value: url.absoluteString),
            URLQueryItem(name: "referrer", value: "https://example.org/page"),
            URLQueryItem(name: "ua", value: "Synthetic Browser/1.0")
        ]
        if let token { components.queryItems?.append(URLQueryItem(name: "token", value: token)) }
        if let filename { components.queryItems?.append(URLQueryItem(name: "filename", value: filename)) }
        return try #require(components.url)
    }

    @Test func privateAtomicFileIsConsumedExactlyOnce() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let request = try DownloadCookieRequest.parse(payload())
        try DownloadCookieHandoff.save(request, directory: root)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: root.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(token).path)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [token])
        #expect(try DownloadCookieHandoff.take(token: token, url: downloadURL, directory: root) == request.cookie)
        #expect(try DownloadCookieHandoff.take(token: token, url: downloadURL, directory: root) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func expiredFilesAreRemovedAtSixtySeconds() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date.now
        let request = try DownloadCookieRequest.parse(payload())
        try DownloadCookieHandoff.save(request, directory: root, now: now)
        #expect(try DownloadCookieHandoff.take(token: token, url: downloadURL, directory: root, now: now.addingTimeInterval(60)) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        try DownloadCookieHandoff.save(request, directory: root, now: now)
        try DownloadCookieHandoff.cleanup(directory: root, now: now.addingTimeInterval(61))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func wrongURLAndUnsafePermissionsDiscardTheFile() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let request = try DownloadCookieRequest.parse(payload())
        try DownloadCookieHandoff.save(request, directory: root)
        #expect(try DownloadCookieHandoff.take(token: token, url: URL(string: "https://other.example.org/archive.zip")!, directory: root) == nil)
        try DownloadCookieHandoff.save(request, directory: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: root.appendingPathComponent(token).path)
        #expect(try DownloadCookieHandoff.take(token: token, url: downloadURL, directory: root) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func readingFreshTokenAlsoCleansExpiredAndInterruptedHandoffs() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date.now
        let request = try DownloadCookieRequest.parse(payload())
        try DownloadCookieHandoff.save(request, directory: root, now: now)
        let expired = root.appendingPathComponent(String(repeating: "b2", count: 16))
        let interrupted = root.appendingPathComponent("interrupted.pending")
        for file in [expired, interrupted] {
            try YtDlpCookieFile.writePrivate(payload(), to: file)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-61)], ofItemAtPath: file.path)
        }
        #expect(try DownloadCookieHandoff.take(token: token, url: downloadURL, directory: root, now: now) == request.cookie)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func malformedAndMismatchedPayloadsAreConsumedWithoutLeakingCredentials() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let request = try DownloadCookieRequest.parse(payload())
        let source = root.appendingPathComponent(token)
        try DownloadCookieHandoff.save(request, directory: root)
        try payload(token: String(repeating: "b2", count: 16)).write(to: source)
        #expect(try DownloadCookieHandoff.take(token: token, url: downloadURL, directory: root) == nil)
        try DownloadCookieHandoff.save(request, directory: root)
        try Data("synthetic-private invalid JSON".utf8).write(to: source)
        do {
            _ = try DownloadCookieHandoff.take(token: token, url: downloadURL, directory: root)
            Issue.record("Malformed payload was accepted")
        } catch {
            #expect(!String(reflecting: error).contains("synthetic-private"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func chromeNativeFrameCarriesDownloadCookieRequest() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("frame")
        let data = try payload()
        var length = UInt32(data.count).littleEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(data)
        try frame.write(to: file)
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        let request = try DownloadCookieRequest.parse(VideoNativeMessaging.readPayload(from: input))
        #expect(request.token == token)
        #expect(request.cookie == "session=synthetic-private")
    }

    @Test(arguments: ["../outside", "", "a", String(repeating: "g", count: 32), String(repeating: "a", count: 33)])
    func rejectsInvalidTokens(_ invalid: String) throws {
        let root = directory()
        #expect(!DownloadCookieRequest.isValidToken(invalid))
        #expect(throws: (any Error).self) { try DownloadCookieRequest.parse(payload(token: invalid)) }
        #expect(throws: (any Error).self) { try DownloadCookieHandoff.take(token: invalid, url: downloadURL, directory: root) }
        #expect(OpenURLRequest.parse(try entry(downloadURL, token: invalid), detectPagePassword: false) == nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func descriptionsAndErrorsNeverIncludeCredentials() throws {
        let request = try DownloadCookieRequest.parse(payload())
        #expect(!String(describing: request).contains("synthetic-private"))
        #expect(!String(reflecting: request).contains("synthetic-private"))
        do {
            _ = try DownloadCookieRequest.parse(payload(cookie: "synthetic-private\r\nInjected: true"))
            Issue.record("Invalid cookie was accepted")
        } catch {
            #expect(!String(describing: error).contains("synthetic-private"))
            #expect(!error.localizedDescription.contains("synthetic-private"))
        }
    }

    @Test func safariAcceptsContextAndRejectsDuplicateMetadata() throws {
        let url = try entry(downloadURL, token: token, filename: "archive.zip")
        #expect(BrowserExtensionRequest.validatedURL(from: ["url": url.absoluteString]) == url)
        for name in ["ua", "filename", "token"] {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.queryItems?.append(URLQueryItem(name: name, value: name == "token" ? token : "duplicate"))
            #expect(BrowserExtensionRequest.validatedURL(from: ["url": components.url!.absoluteString]) == nil)
        }
    }

    @Test func routerConsumesCookieIntoDraftWithoutLeakingIntoURLOrHistory() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try TemporaryDefaults(prefix: "ExtensionHandoff-")
        defer { defaults.clean() }
        let request = try DownloadCookieRequest.parse(payload())
        try DownloadCookieHandoff.save(request, directory: root)
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        let router = OpenURLRouter(model: model, settings: SettingsModel(defaults: defaults.defaults), cookieDirectory: root)
        let url = try entry(downloadURL, token: token)
        #expect(!url.absoluteString.contains("synthetic-private"))
        #expect(router.open([url]))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        let draft = NewTaskModel()
        draft.consumePendingText(from: model)
        #expect(draft.links.first?.requestContext.cookie == request.cookie)
        draft.createTasks(in: model)
        #expect(model.tasks.count == 1)
        #expect(model.tasks.first?.requestContext?.requestCookie == nil)
        #expect(!String(decoding: try JSONEncoder().encode(model.tasks), as: UTF8.self).contains("synthetic-private"))
        #expect(router.open([url]))
        #expect(model.openURLIssue != nil)
        #expect(model.pendingNewTaskContexts.values.allSatisfy { $0.requestContext.cookie == nil })
    }

    @Test func routerAutomaticallyCleansExpiredHandoffsWhileRunning() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try TemporaryDefaults(prefix: "ExtensionHandoffTimer-")
        defer { defaults.clean() }
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        let router = OpenURLRouter(model: model, settings: SettingsModel(defaults: defaults.defaults),
                                   cookieDirectory: root, cleanupInterval: 0.02)
        try DownloadCookieHandoff.save(DownloadCookieRequest.parse(payload()), directory: root)
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-61)],
                                             ofItemAtPath: root.appendingPathComponent(token).path)
        try await Task.sleep(for: .milliseconds(100))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        withExtendedLifetime(router) {}
    }

    @Test func cleanupDoesNotCreateDirectoryAndStopsAtExit() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try TemporaryDefaults(prefix: "ExtensionHandoffExit-")
        defer { defaults.clean() }
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        let router = OpenURLRouter(model: model, settings: SettingsModel(defaults: defaults.defaults),
                                   cookieDirectory: root, cleanupInterval: 0.02)
        try await Task.sleep(for: .milliseconds(60))
        #expect(!FileManager.default.fileExists(atPath: root.path))
        try DownloadCookieHandoff.save(DownloadCookieRequest.parse(payload()), directory: root)
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-61)],
                                             ofItemAtPath: root.appendingPathComponent(token).path)
        router.stopCookieCleanup()
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func routerCleansExpiredHandoffsAtStartup() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try TemporaryDefaults(prefix: "ExtensionHandoffStartup-")
        defer { defaults.clean() }
        try DownloadCookieHandoff.save(DownloadCookieRequest.parse(payload()), directory: root, now: .now.addingTimeInterval(-61))
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        _ = OpenURLRouter(model: model, settings: SettingsModel(defaults: defaults.defaults), cookieDirectory: root)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func browserReplacementConsumesOnlyNextMatchingLinkWithinFiveMinutes() throws {
        let root = directory()
        let defaults = try TemporaryDefaults(prefix: "ExtensionReplacement-")
        defer { defaults.clean() }
        let link = try #require(LinkParser.parse(downloadURL.absoluteString).first)
        let task = DownloadTask(link: link, autoExtract: false)
        let model = AppModel(tasks: [task], preventsSleepWhileDownloading: false)
        let router = OpenURLRouter(model: model, settings: SettingsModel(defaults: defaults.defaults), cookieDirectory: root)
        model.waitForBrowserHTTPReplacement(task.id)
        #expect(router.open([try entry(URL(string: "https://unrelated.example.org/other.zip")!)]))
        #expect(model.waitingHTTPReplacement != nil)
        model.isShowingNewTask = false
        model.pendingNewTaskText = ""
        #expect(router.open([try entry(URL(string: "https://example.org/fresh.zip")!)]))
        #expect(model.waitingHTTPReplacement == nil)
        #expect(model.pendingBrowserHTTPReplacement?.taskID == task.id)
        #expect(model.pendingBrowserHTTPReplacement?.context.userAgent == "Synthetic Browser/1.0")
        #expect(!model.isShowingNewTask)
        #expect(model.pendingNewTaskText.isEmpty)
        #expect(router.open([try entry(downloadURL)]))
        #expect(model.isShowingNewTask)
        model.waitForBrowserHTTPReplacement(task.id, now: .now.addingTimeInterval(-301))
        #expect(!model.acceptBrowserHTTPReplacement(link, context: DownloadRequestContext()))
        #expect(model.waitingHTTPReplacement == nil)
        model.waitForBrowserHTTPReplacement(task.id)
        let other = try #require(LinkParser.parse("https://cdn.example.org/archive.zip").first)
        #expect(model.acceptBrowserHTTPReplacement(other, context: DownloadRequestContext()))
        #expect(model.pendingBrowserHTTPReplacement?.url.host == "cdn.example.org")
    }
}
