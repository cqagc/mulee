import Darwin
import Foundation
import MuleeCore
import Testing
@testable import Mulee

@Suite struct DownloadProvenanceTests {
    @Test func removesCredentialsQueryAndFragment() throws {
        let source = "https://" + "user:password" + "@example.com:8443/files/sample.zip?token=private#section"
        #expect(DownloadProvenance.sanitizedSource(source, filename: "sample.zip") == "https://example.com:8443/files/sample.zip")
        #expect(DownloadProvenance.sanitizedSource("magnet:?xt=urn:btih:abc&tr=https://example.com/private", filename: "sample.bin") == "magnet:sample.bin")
        #expect(DownloadProvenance.sanitizedSource("ed2k://|file|sample.bin|1|abc|/", filename: "sample.bin") == "ed2k:sample.bin")
        #expect(DownloadProvenance.sanitizedSource("https://example.com/文件?q=1", filename: "sample") == "https://example.com/%E6%96%87%E4%BB%B6")
        #expect(DownloadProvenance.sanitizedSource("not a URL", filename: "sample") == nil)
        #expect(DownloadProvenance.sanitizedSource("ed2k", filename: "sample") == nil)
        #expect(DownloadProvenance.sanitizedSource("file:///tmp/example?token=private#section", filename: "sample") == "file:///tmp/example")
        #expect(DownloadProvenance.sanitizedSource("https:///missing-host", filename: "sample") == nil)
    }

    @Test func sourcePageUsesTheSameCleaningAndDeduplicates() {
        var task = MockData.tasks[0]
        task.sourceLink = "https://example.com/file?token=private"
        task.sourcePageURL = URL(string: "https://example.com/page?session=private#fragment")
        #expect(DownloadProvenance.sources(for: task) == ["https://example.com/file", "https://example.com/page"])
        task.sourcePageURL = URL(string: "https://example.com/file?different=1")
        #expect(DownloadProvenance.sources(for: task) == ["https://example.com/file"])
    }

    @Test(arguments: [
        ("https://www.youtube.com/watch?v=Example0001&list=ExampleList&token=private#part", "https://www.youtube.com/watch?v=Example0001&list=ExampleList"),
        ("https://youtu.be/Example0001?list=ExampleList&token=private", "https://www.youtube.com/watch?v=Example0001&list=ExampleList"),
        ("https://www.bilibili.com/video/BVExample001?p=3&token=private", "https://www.bilibili.com/video/BVExample001?p=3"),
        ("https://example.org/watch?v=Example0001&token=private", "https://example.org/watch"),
        ("https://youtube.com.example.org/watch?v=Example0001", "https://youtube.com.example.org/watch")
    ])
    func videoPagesKeepOnlyPublicLocators(source: String, expected: String) {
        var task = MockData.tasks[0]
        task.kind = .video
        task.sourceLink = source
        task.sourcePageURL = nil
        task.requestContext = nil
        #expect(DownloadProvenance.sources(for: task) == [expected])
        task.kind = .http
        #expect(!DownloadProvenance.sources(for: task).contains { $0.contains("?") })
    }

    @Test func videoWhereFromsRetainsEpisodeAndRemovesCredentials() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Example.mp4")
        try Data([1]).write(to: file)
        var task = MockData.tasks[0]
        task.kind = .video
        task.sourceLink = "https://www.youtube.com/watch?v=Example0001&list=ExampleList&token=private"
        task.sourcePageURL = URL(string: "https://" + "user:password" + "@www.bilibili.com/video/BVExample001?p=2&token=private#fragment")
        await DownloadProvenance.apply(to: file, task: task)
        let data = try attribute("com.apple.metadata:kMDItemWhereFroms", at: file)
        #expect(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String] == [
            "https://www.youtube.com/watch?v=Example0001&list=ExampleList",
            "https://www.bilibili.com/video/BVExample001?p=2"
        ])
    }

    @Test func binaryPlistAndQuarantineRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sample.bin")
        try Data([1]).write(to: file)
        let sources = ["https://example.com/sample.bin", "https://example.com/page"]
        try DownloadProvenance.write(to: file, sources: sources)
        let data = try attribute("com.apple.metadata:kMDItemWhereFroms", at: file)
        #expect(data.starts(with: Data("bplist00".utf8)))
        #expect(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String] == sources)
        let quarantine = try attribute("com.apple.quarantine", at: file)
        #expect(String(decoding: quarantine, as: UTF8.self).contains("Mulee"))
    }

    @Test func missingSourceStillQuarantinesAndAppPackagesAreMarked() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("Example.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(DownloadProvenance.apply(to: app, sources: []) == 1)
        #expect(try !attribute("com.apple.quarantine", at: app).isEmpty)
        #expect(DownloadProvenance.apply(to: app, sources: [], limit: 0) == 0)
    }

    @Test @MainActor func extractedFilesInheritSource() async throws {
        let context = try ExtractionTestContext()
        try Data([1]).write(to: context.root.appendingPathComponent("产物.txt"))
        var task = try context.task("sample.zip", status: .completed)
        task.sourceLink = "https://example.com/archive?token=private"
        task.sourcePageURL = URL(string: "https://example.com/page#fragment")
        context.model.tasks = [task]
        context.coordinator.start()
        try await context.waitUntil { context.model.tasks[0].postDownload.extractionState == .succeeded }
        let file = try #require(context.model.tasks[0].postDownload.extractedItems?.first)
        let data = try attribute("com.apple.metadata:kMDItemWhereFroms", at: file)
        #expect(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String] == ["https://example.com/archive", "https://example.com/page"])
        try await context.clean()
    }

    @Test func traversalSkipsSymlinksAndStopsAtLimit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let content = root.appendingPathComponent("download")
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside.bin")
        try Data([1]).write(to: outside)
        for name in ["one.bin", "two.bin"] { try Data([2]).write(to: content.appendingPathComponent(name)) }
        try FileManager.default.createSymbolicLink(at: content.appendingPathComponent("link"), withDestinationURL: outside)
        DownloadProvenance.apply(to: content, sources: ["https://example.com/file"], limit: 1)
        let marked = ["one.bin", "two.bin"].filter {
            (try? attribute("com.apple.metadata:kMDItemWhereFroms", at: content.appendingPathComponent($0))) != nil
        }
        #expect(marked.count == 1)
        #expect(throws: (any Error).self) { try attribute("com.apple.metadata:kMDItemWhereFroms", at: outside) }
        // 不存在的成品只能记录日志，不能向完成流程抛出异常。
        DownloadProvenance.apply(to: root.appendingPathComponent("missing"), sources: ["https://example.com/file"])
    }

    @Test(arguments: [TaskKind.http, .bittorrent, .ed2k, .video])
    @MainActor func everyEngineMarksCompletedFilesBeforePublishing(kind: TaskKind) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sample.bin")
        try Data([1, 2]).write(to: file)
        var task = MockData.tasks[0]
        task.kind = kind
        task.status = .downloading
        task.sourceLink = "https://example.com/sample.bin?token=private"
        task.engineTaskID = "provenance-task"
        task.savePath = file
        let model = AppModel(tasks: [task], preventsSleepWhileDownloading: false)
        let engine = FakeEngine(kind: kind)
        let coordinator = DownloadCoordinator(model: model, engines: [engine])
        await coordinator.start(options: EngineOptions(downloadDirectory: root))
        await engine.setSnapshots([EngineTaskSnapshot(
            engineTaskID: "provenance-task", name: "sample.bin", totalBytes: 2, receivedBytes: 2,
            downloadRate: 0, uploadRate: 0, status: kind == .bittorrent ? .seeding : .completed,
            connections: 0, savePath: file, sourceURL: nil, errorMessage: nil
        )])
        await coordinator.poll()
        await coordinator.stop()
        let data = try attribute("com.apple.metadata:kMDItemWhereFroms", at: file)
        #expect(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String] == ["https://example.com/sample.bin"])
        #expect([.completed, .seeding].contains(model.tasks[0].status))
    }

    private func attribute(_ name: String, at file: URL) throws -> Data {
        let size = getxattr(file.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { throw POSIXError(.ENOATTR) }
        var data = Data(count: size)
        let result = data.withUnsafeMutableBytes { getxattr(file.path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        guard result >= 0 else { throw POSIXError(.EIO) }
        return data
    }
}
