import Foundation
import Testing
@testable import MuleeCore

@Suite struct TorrentPolicyTests {
    @Test("协议状态映射全表", arguments: [
        ("checking", false, false, false, TaskStatus.downloading),
        ("metadata", false, false, false, .downloading),
        ("downloading", false, false, false, .downloading),
        ("downloading", false, true, false, .queued),
        ("seeding", false, false, true, .seeding),
        ("finished", false, false, true, .completed),
        ("error", false, false, false, .failed),
        ("checking", true, false, false, .paused),
        ("metadata", true, false, false, .paused),
        ("downloading", true, true, false, .paused),
        ("error", true, false, false, .paused),
        ("seeding", true, false, true, .completed),
        ("finished", true, false, true, .completed),
        ("downloading", true, false, true, .completed),
        ("unknown", false, false, false, .failed)
    ])
    func statuses(_ state: String, _ paused: Bool, _ queued: Bool, _ completed: Bool, _ expected: TaskStatus) {
        #expect(TorrentStatusMapper.status(state: state, paused: paused, queued: queued, completed: completed) == expected)
    }

    @Test("做种策略的全部分支", arguments: [
        (0.99, false, false, Int64(0), TorrentSeedingAction.stop, false, SeedingPolicyAction.none),
        (1.0, false, false, 0, .stop, false, .pause),
        (2.0, false, true, 0, .stop, false, .none),
        (1.0, true, false, 0, .stop, true, .none),
        (1.0, true, false, 0, .stop, false, .pause),
        (1.0, false, false, 0, .slowDown, true, .setUploadLimit(51_200)),
        (1.0, false, false, 51_200, .slowDown, true, .none),
        (1.0, false, false, 12_345, .slowDown, false, .setUploadLimit(51_200)),
        (1.0, true, false, 0, .slowDown, true, .none),
        (1.0, true, false, 0, .slowDown, false, .setUploadLimit(51_200)),
        (1.0, false, true, 0, .slowDown, false, .setUploadLimit(51_200)),
        (Double.nan, false, false, 0, .stop, false, .none),
        (Double.infinity, false, false, 0, .stop, false, .none)
    ])
    func seeding(
        _ ratio: Double, _ isPrivate: Bool, _ paused: Bool, _ limit: Int64,
        _ policy: TorrentSeedingAction, _ exempt: Bool, _ expected: SeedingPolicyAction
    ) {
        let settings = TorrentEngineSettings(seedingAction: policy, exemptPrivateTorrents: exempt)
        #expect(SeedingPolicy.action(ratio: ratio, isFinished: true, isPrivate: isPrivate, paused: paused, uploadLimit: limit, settings: settings) == expected)
    }

    @Test("下载未完成时分享率不触发策略", arguments: [TorrentSeedingAction.stop, .slowDown])
    func unfinishedPolicy(_ action: TorrentSeedingAction) {
        for isPrivate in [false, true] {
            let settings = TorrentEngineSettings(seedingAction: action, exemptPrivateTorrents: false)
            #expect(SeedingPolicy.action(
                ratio: 3, isFinished: false, isPrivate: isPrivate,
                paused: false, uploadLimit: 0, settings: settings
            ) == .none)
        }
    }

    @Test("选择性下载按所选内容完成，恢复校验和历史完成时间不触发", arguments: [
        ("downloading", false, Int64(600), false),
        ("checking", true, 1234, false),
        ("metadata", true, 1234, false),
        ("seeding", true, 600, false),
        ("seeding", true, 1234, true),
        ("finished", true, 1234, true)
    ])
    func selectedCompletion(_ state: String, _ finished: Bool, _ done: Int64, _ expected: Bool) throws {
        let task = try TorrentFixtures.decodeTask(TorrentFixtures.task([
            "state": .string(state), "is_finished": .bool(finished),
            "total_wanted_done": .integer(done), "completed_at": .integer(200),
            "is_private": .bool(true), "ratio": .double(3)
        ]))
        #expect(task.selectedFileCount < task.fileCount)
        #expect(task.canApplySeedingPolicy == expected)
        let noSelection = try TorrentFixtures.decodeTask(TorrentFixtures.task([
            "selected_file_count": .integer(0), "total_wanted": .integer(0)
        ]))
        #expect(!noSelection.canApplySeedingPolicy)
        let oldHelper = try TorrentFixtures.decodeTask(TorrentFixtures.task(["is_finished": .null]))
        #expect(!oldHelper.canApplySeedingPolicy)
    }

    @Test("快照详情、路径、完成时间，元数据未知时大小为 nil")
    func snapshot() throws {
        let value = try TorrentFixtures.decodeTask(TorrentFixtures.task())
        let snapshot = TorrentStatusMapper.snapshot(value)
        #expect(snapshot.engineTaskID == TorrentFixtures.id)
        #expect(snapshot.name == "Ubuntu")
        #expect(snapshot.totalBytes == 1234)
        #expect(snapshot.receivedBytes == 1234)
        #expect(snapshot.downloadRate == 0)
        #expect(snapshot.uploadRate == 321)
        #expect(snapshot.connections == 3)
        #expect(snapshot.status == .seeding)
        #expect(snapshot.savePath?.path == "/tmp/downloads/Ubuntu")
        #expect(snapshot.sourceURL?.absoluteString == TorrentFixtures.magnet.original)
        #expect(snapshot.completedAt == Date(timeIntervalSince1970: 200))
        #expect(snapshot.detail == .bittorrent(fileCount: 4, selectedFileCount: 2, peerCount: 3, shareRatio: 0.5))
        #expect(snapshot.errorMessage == nil)
        let unknown = try TorrentFixtures.decodeTask(TorrentFixtures.task([
            "has_metadata": .bool(false), "total_wanted": .integer(0), "total_wanted_done": .integer(0),
            "content_path": .null, "state": .string("metadata"), "completed_at": .null
        ]))
        let metadata = TorrentStatusMapper.snapshot(unknown)
        #expect(metadata.totalBytes == nil)
        #expect(metadata.savePath == nil)
        #expect(metadata.completedAt == nil)
        #expect(metadata.status == .downloading)
    }

    @Test("任务错误为用户可读中文")
    func failure() throws {
        let value = try TorrentFixtures.decodeTask(TorrentFixtures.task([
            "state": .string("error"), "error": .string("No space left on device")
        ]))
        #expect(TorrentStatusMapper.snapshot(value).errorMessage == String(localized: "磁盘空间不足", bundle: .module))
    }

    @Test("二进制按显式路径、包内、环境变量查找")
    func binaryLocator() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bundled = root.appendingPathComponent("Contents/Helpers/mulee-torrentd")
        try FileManager.default.createDirectory(at: bundled.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: bundled, withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        let explicit = URL(fileURLWithPath: "/bin/echo")
        let environment = ["MULEE_TORRENTD": "/usr/bin/false"]
        #expect(try TorrentBinaryLocator.locate(explicitURL: explicit, bundleURL: root, environment: environment) == explicit)
        #expect(try TorrentBinaryLocator.locate(explicitURL: nil, bundleURL: root, environment: environment) == bundled)
        try FileManager.default.removeItem(at: bundled)
        #expect(try TorrentBinaryLocator.locate(explicitURL: nil, bundleURL: root, environment: environment).path == "/usr/bin/false")
        #expect(throws: EngineError.binaryNotFound) {
            try TorrentBinaryLocator.locate(explicitURL: root, bundleURL: root, environment: [:])
        }
    }
}
