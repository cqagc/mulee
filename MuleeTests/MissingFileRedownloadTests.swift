import Foundation
import MuleeCore
import Testing
@testable import Mulee

@Suite @MainActor
struct MissingFileRedownloadTests {
    @Test func aria2RedownloadsDeletedHTTPOutputEndToEnd() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Mulee-redownload-e2e-\(UUID())")
        let state = root.appending(path: "aria2")
        let serverRoot = root.appending(path: "server")
        try FileManager.default.createDirectory(at: serverRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let payload = Data((0..<32_768).map { UInt8($0 % 251) })
        let source = serverRoot.appending(path: "fixture.bin")
        try payload.write(to: source)
        let server = Process()
        let portFile = root.appending(path: "port")
        server.executableURL = URL(filePath: "/usr/bin/python3")
        server.arguments = ["-I", "-c", """
            import http.server, pathlib, sys
            server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), http.server.SimpleHTTPRequestHandler)
            pathlib.Path(sys.argv[1]).write_text(str(server.server_port))
            server.serve_forever()
            """, portFile.path]
        server.currentDirectoryURL = serverRoot
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer {
            if server.isRunning { server.terminate() }
            server.waitUntilExit()
        }
        try await waitUntil { (try? String(contentsOf: portFile, encoding: .utf8)).flatMap(Int.init) != nil }
        let port = try #require(Int(try String(contentsOf: portFile, encoding: .utf8)))
        let engine = Aria2Engine(stateDirectory: state, proxyProvider: { HTTPProxyConfiguration(mode: .off) })
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        let coordinator = DownloadCoordinator(model: model, engines: [engine])
        let options = EngineOptions(downloadDirectory: root.appending(path: "downloads"))
        await coordinator.start(options: options)
        do {

            let link = try #require(LinkParser.parse("http://127.0.0.1:\(port)/fixture.bin").first)
            await coordinator.add(links: [link], autoExtract: false, directory: options.downloadDirectory)
            let task = try #require(model.tasks.first)
            try await waitUntil { model.tasks.first?.status == .completed }
            let firstOutput = try #require(model.tasks.first?.savePath)
            #expect(try Data(contentsOf: firstOutput) == payload)

            try FileManager.default.removeItem(at: firstOutput)
            model.refreshTrackedFile(task.id)
            #expect(model.tasks.first?.fileMissing == true)
            try await coordinator.redownloadMissingFile(task.id)
            try await waitUntil { model.tasks.first?.status == .completed && model.tasks.first?.fileMissing != true }

            let secondOutput = try #require(model.tasks.first?.savePath)
            #expect(try Data(contentsOf: secondOutput) == payload)
            #expect(model.tasks.count == 1)
        } catch {
            await coordinator.stop()
            throw error
        }
        await coordinator.stop()
    }

    @Test func redownloadAddsTheOriginalHTTPLinkAndKeepsDestination() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Mulee-redownload-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let link = try #require(LinkParser.parse("https://example.com/fixture.bin").first)
        var task = DownloadTask(link: link, autoExtract: false)
        task.status = .completed
        task.completedAt = .now
        task.fileMissing = true
        task.savePath = root.appending(path: "fixture.bin")
        let model = AppModel(tasks: [task], preventsSleepWhileDownloading: false)
        let engine = FakeEngine()
        let coordinator = DownloadCoordinator(model: model, engines: [engine])
        await coordinator.start(options: EngineOptions(downloadDirectory: root))

        try await coordinator.redownloadMissingFile(task.id)

        #expect(await engine.addedLinks.map(\.original) == [link.original])
        #expect(await engine.directories.compactMap { $0?.standardizedFileURL.path } == [root.standardizedFileURL.path])
        #expect(model.tasks.first?.id == task.id)
        #expect(model.tasks.first?.savePath == task.savePath)
        #expect(model.tasks.first?.fileMissing == false)
        #expect(model.tasks.first?.status == .queued)
        #expect(model.tasks.first?.completedAt == nil)
        await coordinator.stop()
    }

    @Test func redownloadRefusesToReplaceAnExistingOutput() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Mulee-redownload-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let output = root.appending(path: "fixture.bin")
        try Data("keep".utf8).write(to: output)
        let link = try #require(LinkParser.parse("https://example.com/fixture.bin").first)
        var task = DownloadTask(link: link, autoExtract: false)
        task.status = .completed
        task.completedAt = .now
        task.fileMissing = true
        task.savePath = output
        let model = AppModel(tasks: [task], preventsSleepWhileDownloading: false)
        let engine = FakeEngine()
        let coordinator = DownloadCoordinator(model: model, engines: [engine])
        await coordinator.start(options: EngineOptions(downloadDirectory: root))

        await #expect(throws: EngineError.self) {
            try await coordinator.redownloadMissingFile(task.id)
        }
        #expect(await engine.addedLinks.isEmpty)
        #expect(try String(contentsOf: output, encoding: .utf8) == "keep")
        await coordinator.stop()
    }

    private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
        try #require(predicate())
    }
}
