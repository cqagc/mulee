import Foundation
import MuleeCore
import Testing
@testable import Mulee

@Suite @MainActor struct HTTPDownloadTests {
    @Test(arguments: [false, true])
    func pauseDuringResumePreflightWins(_ probeFails: Bool) async throws {
        let link = try #require(LinkParser.parse("https://example.org/archive.bin").first)
        var task = DownloadTask(link: link, autoExtract: false)
        task.engineTaskID = "http-race"
        task.status = .paused
        task.httpIdentity = HTTPResourceIdentity(size: 100)
        let model = AppModel(tasks: [task], preventsSleepWhileDownloading: false)
        let engine = FakeEngine()
        var continuation: CheckedContinuation<HTTPResourceIdentity, any Error>?
        let coordinator = DownloadCoordinator(model: model, engines: [engine], inspectHTTP: { _, _, _ in
            try await withCheckedThrowingContinuation { continuation = $0 }
        })
        await coordinator.start(options: EngineOptions(downloadDirectory: FileManager.default.temporaryDirectory))
        let resume = Task { await coordinator.resume(task.id) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while continuation == nil, ContinuousClock.now < deadline { await Task.yield() }
        let response = try #require(continuation)
        model.userPausedTaskIDs.insert(task.id)
        await coordinator.pause(task.id)
        if probeFails { response.resume(throwing: HTTPDownloadFailure.resourceChanged) }
        else { response.resume(returning: HTTPResourceIdentity(size: 100)) }
        await resume.value
        #expect(model.tasks.first?.status == .paused)
        #expect(model.userPausedTaskIDs.contains(task.id))
        #expect(model.tasks.first?.httpValidationError == nil)
        await coordinator.stop()
    }

    @Test(arguments: [false, true])
    func deletingOrExpiringHTTPRecordExcludesCompletedSnapshots(_ expire: Bool) async throws {
        let link = try #require(LinkParser.parse("https://example.org/archive.bin").first)
        var task = DownloadTask(link: link, autoExtract: false)
        task.engineTaskID = "completed-http"
        task.status = .completed
        task.deletedAt = .now.addingTimeInterval(-TaskTrash.retention)
        let model = AppModel(tasks: [task], preventsSleepWhileDownloading: false)
        let engine = FakeEngine()
        let coordinator = DownloadCoordinator(model: model, engines: [engine])
        await coordinator.start(options: EngineOptions(downloadDirectory: FileManager.default.temporaryDirectory))
        await engine.setSnapshots([EngineTaskSnapshot(
            engineTaskID: "completed-http", name: "archive.bin", totalBytes: 100, receivedBytes: 100,
            downloadRate: 0, uploadRate: 0, status: .completed, connections: 0,
            savePath: nil, sourceURL: URL(string: link.original), errorMessage: nil
        )])
        if expire { model.purgeExpiredTrash() }
        else { model.removeRecord(task.id) }
        await coordinator.poll()
        #expect(model.tasks.isEmpty)
        await coordinator.stop()
    }

    @Test func handoffPreservesContextThroughDraftAndHistory() throws {
        var components = URLComponents()
        components.scheme = "mulee"
        components.host = "add"
        components.queryItems = [
            URLQueryItem(name: "url", value: "https://example.org/archive.zip"),
            URLQueryItem(name: "referrer", value: "https://example.org/page"),
            URLQueryItem(name: "ua", value: "Browser/1"),
            URLQueryItem(name: "filename", value: "suggested.zip"),
            URLQueryItem(name: "cookie", value: "must-not-be-accepted")
        ]
        let url = try #require(components.url)
        let request = try #require(OpenURLRequest.parse(url, detectPagePassword: false))
        #expect(request.requestContext.referer?.path == "/page")
        #expect(request.requestContext.userAgent == "Browser/1")
        #expect(request.requestContext.suggestedFilename == "suggested.zip")
        #expect(request.requestContext.requestCookie == nil)
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        let router = OpenURLRouter(model: model, settings: SettingsModel())
        #expect(router.open([url]))
        #expect(model.tasks.isEmpty)
        let draft = NewTaskModel()
        draft.consumePendingText(from: model)
        #expect(draft.links.first?.requestContext == request.requestContext)
        #expect(draft.links.first?.name == "suggested.zip")
        draft.links.first?.checksumText = String(repeating: "a", count: 64)
        draft.createTasks(in: model)
        let task = try #require(model.tasks.first)
        #expect(task.name == "suggested.zip")
        #expect(task.requestContext == request.requestContext)
        #expect(task.checksum?.algorithm == .sha256)
        let encoded = try JSONEncoder().encode(task)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("must-not-be-accepted"))
        #expect(try JSONDecoder().decode(DownloadTask.self, from: encoded).checksum == task.checksum)
    }

    @Test func rejectsInjectedHandoffContext() throws {
        for item in [URLQueryItem(name: "ua", value: "Browser\r\nCookie: secret"), URLQueryItem(name: "filename", value: "../archive.zip")] {
            var components = URLComponents(string: "mulee://add")
            components?.queryItems = [URLQueryItem(name: "url", value: "https://example.org/archive.zip"), item]
            #expect(OpenURLRequest.parse(try #require(components?.url), detectPagePassword: false) == nil)
        }
    }

    @Test func coordinatorKeepsContextAndChecksumWithoutCookiePlaintext() async throws {
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        let engine = FakeEngine()
        let coordinator = DownloadCoordinator(model: model, engines: [engine])
        let root = FileManager.default.temporaryDirectory
        await coordinator.start(options: EngineOptions(downloadDirectory: root))
        let link = try #require(LinkParser.parse("https://example.org/archive.zip").first)
        let context = DownloadRequestContext(userAgent: "Browser/1", headers: ["Cookie": "private-value"], cookie: "private-value")
        let checksum = try #require(DownloadChecksum.parse(String(repeating: "a", count: 64)))
        await coordinator.add(links: [link], autoExtract: false, requestContexts: [link: context], checksums: [link: checksum])
        let task = try #require(model.tasks.first)
        #expect(task.requestContext?.userAgent == "Browser/1")
        #expect(task.requestContext?.requestCookie == nil)
        #expect(task.checksum == checksum)
        #expect(!String(decoding: try JSONEncoder().encode(task), as: UTF8.self).contains("private-value"))
        await coordinator.stop()
    }

    @Test func completedNonHTTPTaskDiscoversAndVerifiesChecksum() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HTTPDownloadTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("archive.bin")
        try Data("abc".utf8).write(to: file)
        let digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        try "\(digest)  archive.bin\n".write(to: root.appendingPathComponent("SHA256SUMS"), atomically: true, encoding: .utf8)
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        let engine = FakeEngine(kind: .ed2k)
        let coordinator = DownloadCoordinator(model: model, engines: [engine])
        await coordinator.start(options: EngineOptions(downloadDirectory: root))
        await engine.setSnapshots([EngineTaskSnapshot(
            engineTaskID: "task-checksum", name: "archive.bin", totalBytes: 3, receivedBytes: 3,
            downloadRate: 0, uploadRate: 0, status: .completed, connections: 0, savePath: file,
            sourceURL: nil, errorMessage: nil
        )])
        await coordinator.poll()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while model.tasks.first?.checksumVerification == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.tasks.first?.checksumVerification?.matches == true)
        #expect(model.tasks.first?.checksum?.digest == digest)
        await coordinator.stop()
    }

    @Test func optionalHTTPFieldsKeepLegacyHistoryDecodable() throws {
        let link = try #require(LinkParser.parse("https://example.org/archive.zip").first)
        let task = DownloadTask(link: link, autoExtract: false)
        let data = try JSONEncoder().encode(task)
        let decoded = try JSONDecoder().decode(DownloadTask.self, from: data)
        #expect(decoded.requestContext == nil)
        #expect(decoded.httpIdentity == nil)
        #expect(decoded.checksumVerification == nil)
    }

    @Test func downloadedLoginPageNeverBecomesCompletedTask() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("HTTP-page-\(UUID()).zip")
        try Data("<!doctype html><html>Login required</html>".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        let engine = FakeEngine()
        let coordinator = DownloadCoordinator(model: model, engines: [engine])
        await coordinator.start(options: EngineOptions(downloadDirectory: file.deletingLastPathComponent()))
        await engine.setSnapshots([EngineTaskSnapshot(
            engineTaskID: "page-task", name: file.lastPathComponent, totalBytes: 42, receivedBytes: 42,
            downloadRate: 0, uploadRate: 0, status: .completed, connections: 0, savePath: file,
            sourceURL: nil, errorMessage: nil
        )])
        await coordinator.poll()
        #expect(model.tasks.first?.status == .failed)
        #expect(model.tasks.first?.errorMessage == HTTPDownloadFailure.webPage.localizedDescription)
        await coordinator.stop()
    }
}
