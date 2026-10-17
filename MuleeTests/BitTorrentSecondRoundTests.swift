import AppKit
import Foundation
import Testing
import zlib
@testable import Mulee
import MuleeCore

@Suite @MainActor struct BitTorrentSecondRoundTests {
    private enum Failure: Error { case download, parse, trash }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bt-update-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func blocklistSuccessIntervalAndRelaunch() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("example:192.0.2.1-192.0.2.2\n".utf8)
        var downloads = 0
        let updater = IPBlocklistUpdater(directory: root) { _ in downloads += 1; return bytes }
        let date = Date(timeIntervalSince1970: 1000)
        await updater.refresh(url: "https://example.com/list", now: date) { file in
            let data = try Data(contentsOf: file)
            #expect(data == bytes)
        }
        #expect(downloads == 1 && updater.lastUpdate == date)
        #expect(try Data(contentsOf: #require(updater.cachedFile)) == bytes)
        await updater.refresh(url: "https://example.com/list", now: date.addingTimeInterval(IPBlocklistUpdater.interval - 1)) { _ in }
        #expect(downloads == 1)
        let relaunched = IPBlocklistUpdater(directory: root) { _ in downloads += 1; return bytes }
        await relaunched.refresh(url: "https://example.com/list", now: date.addingTimeInterval(10)) { _ in }
        #expect(downloads == 1 && relaunched.lastUpdate == date)
        await relaunched.refresh(url: "https://example.com/list", now: date.addingTimeInterval(IPBlocklistUpdater.interval)) { _ in }
        #expect(downloads == 2)
    }

    @Test func downloadAndParseFailuresPreserveCache() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = Data("old-list".utf8)
        let cache = root.appendingPathComponent("subscription.dat")
        try old.write(to: cache)
        let failed = IPBlocklistUpdater(directory: root) { _ in throw Failure.download }
        await failed.refresh(url: "https://example.com/list") { _ in Issue.record("下载失败后不应校验") }
        #expect(try Data(contentsOf: cache) == old)
        #expect(failed.lastUpdate == nil && failed.result != nil)
        let invalid = IPBlocklistUpdater(directory: root) { _ in Data("invalid".utf8) }
        await invalid.refresh(url: "https://example.com/invalid") { _ in throw Failure.parse }
        #expect(try Data(contentsOf: cache) == old)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(Set(remaining) == ["subscription.dat", "state.json"])
    }

    @Test func gzipAndSizeLimits() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let compressed = try #require(Data(base64Encoded: "H4sIAAAAAAAA/0utSMwtyEm1MrQ00jPQM9Iz1IWxjLgA3LLZRRwAAAA="))
        let expected = Data("example:192.0.2.1-192.0.2.2\n".utf8)
        let updater = IPBlocklistUpdater(directory: root) { _ in compressed }
        await updater.refresh(url: "https://example.com/list.gz") { file in
            let data = try Data(contentsOf: file)
            #expect(data == expected)
        }
        #expect(try Data(contentsOf: #require(updater.cachedFile)) == expected)
        let oversized = IPBlocklistUpdater(directory: root) { _ in Data(count: IPBlocklistUpdater.maximumBytes + 1) }
        await oversized.refresh(url: "https://example.com/large") { _ in Issue.record("超限文件不应校验") }
        #expect(try Data(contentsOf: #require(oversized.cachedFile)) == expected)
        await #expect(throws: (any Error).self) { try await IPBlocklistUpdater.decoded(compressed.dropLast()) }
        let invalidURL = IPBlocklistUpdater(directory: root) { _ in
            Issue.record("无效网址不应下载")
            return Data()
        }
        await invalidURL.refresh(url: "file:///tmp/list") { _ in }
        #expect(try Data(contentsOf: #require(invalidURL.cachedFile)) == expected)
    }

    @Test func gzipExpansionLimitPreservesOldFile() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = Data("old".utf8)
        let cache = root.appendingPathComponent("subscription.dat")
        try old.write(to: cache)
        let compressed = try gzip(Data(count: IPBlocklistUpdater.maximumBytes + 1))
        #expect(compressed.count < IPBlocklistUpdater.maximumBytes)
        let updater = IPBlocklistUpdater(directory: root) { _ in compressed }
        await updater.refresh(url: "https://example.com/expansion.gz") { _ in Issue.record("解压超限不应校验") }
        #expect(try Data(contentsOf: cache) == old)
    }

    private func gzip(_ data: Data) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY,
                           ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw Failure.parse }
        defer { deflateEnd(&stream) }
        return try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)
            var output = Data()
            var chunk = [UInt8](repeating: 0, count: 64 * 1_024)
            while true {
                let status = chunk.withUnsafeMutableBytes { buffer in
                    stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(buffer.count)
                    return deflate(&stream, Z_FINISH)
                }
                output.append(contentsOf: chunk.prefix(chunk.count - Int(stream.avail_out)))
                if status == Z_STREAM_END { return output }
                guard status == Z_OK else { throw Failure.parse }
            }
        }
    }

    @Test func trashOnlySuccessfulFinderSources() throws {
        let local = ParsedLink.torrentFile(url: URL(filePath: "/tmp/example.torrent"), original: "file:///tmp/example.torrent")
        let remote = ParsedLink.torrentFile(url: URL(string: "https://example.com/example.torrent")!, original: "https://example.com/example.torrent")
        var trashed: [URL] = []
        for (link, finder, enabled, success) in [
            (local, true, true, true), (local, false, true, true), (local, true, false, true),
            (local, true, true, false), (remote, true, true, true)
        ] {
            try OpenURLRouter.trashAddedTorrent(link, fromFinder: finder, enabled: enabled, succeeded: success) { trashed.append($0) }
        }
        #expect(trashed == [URL(filePath: "/tmp/example.torrent")])
        #expect(throws: Failure.trash) {
            try OpenURLRouter.trashAddedTorrent(local, fromFinder: true, enabled: true, succeeded: true) { _ in throw Failure.trash }
        }
    }

    @Test func sourceTaggingAndSettingPersistence() throws {
        let defaults = try TemporaryDefaults(prefix: "bt-second-round.")
        defer { defaults.clean() }
        let settings = SettingsModel(defaults: defaults.defaults)
        #expect(settings.ipBlocklistURL.isEmpty && !settings.trashTorrentAfterAdd)
        settings.ipBlocklistURL = "https://example.com/list.gz"
        settings.trashTorrentAfterAdd = true
        let restored = SettingsModel(defaults: defaults.defaults)
        #expect(restored.ipBlocklistURL == settings.ipBlocklistURL && restored.trashTorrentAfterAdd)
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let router = OpenURLRouter(model: model, settings: settings, cookieDirectory: root)
        defer { router.stopCookieCleanup() }
        let file = root.appendingPathComponent("example.torrent")
        #expect(router.open([file]))
        #expect(model.pendingNewTaskContexts.values.first?.finderTorrent == true)
        model.pendingNewTaskContexts = [:]
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString(file.absoluteString, forType: .fileURL)
        #expect(OpenURLDropHandler.accept(pasteboard, model: model))
        #expect(model.pendingNewTaskContexts.values.first?.finderTorrent == true)
        model.pendingNewTaskContexts = [:]
        pasteboard.clearContents()
        pasteboard.setString(file.path, forType: .string)
        #expect(OpenURLDropHandler.accept(pasteboard, model: model))
        #expect(model.pendingNewTaskContexts.isEmpty)
        #expect(!NewTaskContext().finderTorrent)
    }
}
