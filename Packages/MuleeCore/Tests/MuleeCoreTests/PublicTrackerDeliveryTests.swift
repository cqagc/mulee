import Foundation
import Testing
@testable import MuleeCore

@Suite struct PublicTrackerDeliveryTests {
    @Test("私有与无元数据不追加；磁力取得元数据后追加且不重复")
    func metadataAndPrivacy() async throws {
        let fake = TorrentFakeTransport()
        try await TorrentFixtures.withEngine(fake: fake) { engine, root in
            try await engine.start(options: EngineOptions(downloadDirectory: root))
            await fake.setResult("add_trackers", .object(["added": .integer(1), "total": .integer(2)]))
            await engine.configurePublicTrackers(["https://tracker.example.com/announce"])
            for metadata in [false, true] {
                await fake.setResult("list", .object(["torrents": .array([TorrentFixtures.task([
                    "is_private": .bool(true), "has_metadata": .bool(metadata)
                ])])]))
                _ = try await engine.snapshots()
            }
            await fake.setResult("list", .object(["torrents": .array([TorrentFixtures.task([
                "is_private": .bool(false), "has_metadata": .bool(false)
            ])])]))
            _ = try await engine.snapshots()
            #expect(await additions(fake).isEmpty)
            await fake.setResult("list", .object(["torrents": .array([TorrentFixtures.task([
                "is_private": .bool(false), "has_metadata": .bool(true)
            ])])]))
            _ = try await engine.snapshots()
            _ = try await engine.snapshots()
            #expect(await additions(fake).count == 1)
            await engine.configurePublicTrackers([])
            _ = try await engine.snapshots()
            #expect(await additions(fake).count == 1)
            await engine.configurePublicTrackers(["https://tracker.example.com/announce"])
            _ = try await engine.snapshots()
            #expect(await additions(fake).count == 2)
            try await engine.remove(TorrentFixtures.id, deleteFiles: false)
            _ = try await engine.add(link: TorrentFixtures.magnet, directory: root)
            _ = try await engine.snapshots()
            #expect(await additions(fake).count == 3)
        }
    }

    @Test("现有与新任务都追加，列表校验去重并限制 50 条")
    func existingAndNewTasks() async throws {
        let fake = TorrentFakeTransport()
        try await TorrentFixtures.withEngine(fake: fake) { engine, root in
            try await engine.start(options: EngineOptions(downloadDirectory: root))
            await fake.setResult("list", .object(["torrents": .array([TorrentFixtures.task()])]))
            _ = try await engine.snapshots()
            #expect(await additions(fake).isEmpty)
            let urls = (0..<60).map { "https://tracker\($0).example.com/announce" }
            await engine.configurePublicTrackers(["invalid", urls[0]] + urls)
            await fake.setResult("add_trackers", .object(["added": .integer(49), "total": .integer(50)]))
            _ = try await engine.snapshots()
            let first = try #require(await additions(fake).first)
            #expect(first.parameters["urls"] == .array(Array(urls.prefix(50)).map(TorrentdValue.string)))
            await fake.setResult("list", .object(["torrents": .array([
                TorrentFixtures.task(), TorrentFixtures.task(["id": .string("new-task")])
            ])]))
            _ = try await engine.snapshots()
            #expect(await additions(fake).count == 2)
            #expect(await additions(fake).last?.parameters["id"] == .string("new-task"))
        }
    }

    @Test("helper 拒绝元数据时下轮重试，私有拒绝不重试", arguments: ["metadata_pending", "private_torrent"])
    func rejectedDelivery(_ code: String) async throws {
        let fake = TorrentFakeTransport()
        try await TorrentFixtures.withEngine(fake: fake) { engine, root in
            try await engine.start(options: EngineOptions(downloadDirectory: root))
            await fake.setResult("list", .object(["torrents": .array([TorrentFixtures.task()])]))
            await fake.setError("add_trackers", code: code)
            await engine.configurePublicTrackers(["https://tracker.example.com/announce"])
            _ = try await engine.snapshots()
            await fake.setError("add_trackers", code: nil)
            await fake.setResult("add_trackers", .object(["added": .integer(1), "total": .integer(2)]))
            _ = try await engine.snapshots()
            #expect(await additions(fake).count == (code == "metadata_pending" ? 2 : 1))
        }
    }

    @Test("总数达到上限时缩小批次，不让订阅拖垮快照")
    func trackerLimit() async throws {
        let fake = TorrentFakeTransport()
        try await TorrentFixtures.withEngine(fake: fake) { engine, root in
            try await engine.start(options: EngineOptions(downloadDirectory: root))
            await fake.setResult("list", .object(["torrents": .array([TorrentFixtures.task()])]))
            await fake.setError("add_trackers", code: "tracker_limit")
            await engine.configurePublicTrackers((0..<50).map { "https://tracker\($0).example.com/announce" })
            #expect(try await engine.snapshots().count == 1)
            let requests = await additions(fake)
            #expect(requests.count == 6)
            _ = try await engine.snapshots()
            #expect(await additions(fake).count == 6)
        }
    }

    private func additions(_ fake: TorrentFakeTransport) async -> [TorrentTestRequest] {
        await fake.sent.filter { $0.method == "add_trackers" }
    }
}
