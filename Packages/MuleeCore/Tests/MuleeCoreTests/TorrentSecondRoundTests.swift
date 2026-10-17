import Foundation
import Testing
@testable import MuleeCore

@Suite struct TorrentSecondRoundTests {
    @Test func magnetAndTaskLimitsRoundTrip() async throws {
        let fake = TorrentFakeTransport()
        let uri = "magnet:?xt=urn:btih:\(TorrentFixtures.id)&dn=Example"
        await fake.setResult("magnet_uri", .object(["uri": .string(uri)]))
        try await TorrentFixtures.withEngine(fake: fake) { engine, directory in
            try await engine.start(options: EngineOptions(downloadDirectory: directory))
            #expect(try await engine.magnetURI(TorrentFixtures.id) == uri)
            #expect(await fake.sent.last?.parameters == ["id": .string(TorrentFixtures.id)])
            try await engine.setTaskLimits(id: TorrentFixtures.id, download: 1234, upload: 0)
            #expect(await fake.sent.last?.method == "set_task_limits")
            #expect(await fake.sent.last?.parameters == [
                "id": .string(TorrentFixtures.id), "download_limit": .integer(1234), "upload_limit": .integer(0)
            ])
            for invalid in [Int64(-1), Int64(Int32.max) + 1] {
                await #expect(throws: (any Error).self) {
                    try await engine.setTaskLimits(id: TorrentFixtures.id, download: invalid, upload: 0)
                }
                await #expect(throws: (any Error).self) {
                    try await engine.setTaskLimits(id: TorrentFixtures.id, download: 0, upload: invalid)
                }
            }
            await fake.setError("magnet_uri", code: "metadata_pending")
            await #expect(throws: (any Error).self) { try await engine.magnetURI(TorrentFixtures.id) }
            await fake.setError("set_task_limits", code: "not_found")
            await #expect(throws: (any Error).self) {
                try await engine.setTaskLimits(id: "missing", download: 0, upload: 0)
            }
        }
    }

    @Test func decodesUserLimitsAndPreservesPolicyLimit() async throws {
        let fake = TorrentFakeTransport()
        await fake.setResult("list", .object(["torrents": .array([TorrentFixtures.task([
            "user_download_limit": .integer(1000), "user_upload_limit": .integer(20000),
            "upload_limit": .integer(20000), "policy_upload_limit": .integer(51200), "ratio": .double(2)
        ])])]))
        try await TorrentFixtures.withEngine(fake: fake, settings: TorrentEngineSettings(seedingAction: .slowDown)) { engine, directory in
            try await engine.start(options: EngineOptions(downloadDirectory: directory))
            let info = try await engine.taskInfo(TorrentFixtures.id)
            #expect(info.userDownloadLimit == 1000 && info.userUploadLimit == 20000)
            _ = try await engine.snapshots()
            #expect(await fake.sent.filter { $0.method == "set_upload_limit" }.isEmpty)
            #expect(try TorrentFixtures.decodeTask(TorrentFixtures.task()).userUploadLimit == nil)
            await fake.setResult("magnet_uri", .object([:]))
            await #expect(throws: (any Error).self) { try await engine.magnetURI(TorrentFixtures.id) }
        }
    }

    @Test func subscriptionConfigurationAndValidationOnly() async throws {
        let fake = TorrentFakeTransport()
        await fake.setResult("import_ip_blocklist", .object(["blocked_ranges": .integer(2)]))
        var settings = TorrentEngineSettings(ipBlocklistPath: "/tmp/local.dat")
        settings.ipBlocklistURLPath = "/tmp/subscribed.dat"
        try await TorrentFixtures.withEngine(fake: fake, settings: settings) { engine, directory in
            try await engine.start(options: EngineOptions(downloadDirectory: directory))
            let configure = await fake.sent.first { $0.method == "configure" }
            #expect(configure?.parameters["ip_blocklist_url_path"] == .string("/tmp/subscribed.dat"))
            #expect(configure?.parameters["ip_blocklist_path"] == .string("/tmp/local.dat"))
            let file = directory.appendingPathComponent("candidate.dat")
            #expect(try await engine.importIPBlocklist(from: file, validateOnly: true).blockedRanges == 2)
            #expect(await fake.sent.last?.parameters["validate_only"] == .bool(true))
        }
    }
}
