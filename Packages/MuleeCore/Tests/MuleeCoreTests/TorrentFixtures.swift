import CryptoKit
import Foundation
@testable import MuleeCore

enum TorrentFixtures {
    static let id = "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c"
    static let magnet = ParsedLink.magnet(infoHash: id, displayName: "Ubuntu", original: "magnet:?xt=urn:btih:\(id)&dn=Ubuntu")

    static func task(_ overrides: [String: TorrentdValue] = [:]) -> TorrentdValue {
        var values: [String: TorrentdValue] = [
            "id": .string(id), "name": .string("Ubuntu"), "save_path": .string("/tmp/downloads"),
            "content_path": .string("/tmp/downloads/Ubuntu"), "has_metadata": .bool(true),
            "is_finished": .bool(true), "sequential_download": .bool(false), "first_last_priority": .bool(false),
            "state": .string("seeding"), "paused": .bool(false), "queued": .bool(false),
            "total_wanted": .integer(1234), "total_wanted_done": .integer(1234), "progress": .double(1),
            "download_rate": .integer(0), "upload_rate": .integer(321),
            "all_time_download": .integer(1234), "all_time_upload": .integer(617), "ratio": .double(0.5),
            "num_peers": .integer(3), "num_seeds": .integer(2), "list_peers": .integer(10), "list_seeds": .integer(5),
            "file_count": .integer(4), "selected_file_count": .integer(2), "is_private": .bool(false),
            "upload_limit": .integer(0), "error": .null, "source": .string(magnet.original),
            "added_at": .integer(100), "completed_at": .integer(200), "eta": .null
        ]
        values.merge(overrides) { _, new in new }
        return .object(values)
    }

    static func decodeTask(_ value: TorrentdValue) throws -> TorrentdTask {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(TorrentdTask.self, from: JSONEncoder().encode(value))
    }

    static func bytes(_ data: Data) -> Data {
        Data("\(data.count):".utf8) + data
    }

    static func string(_ text: String) -> Data { bytes(Data(text.utf8)) }

    static func torrent(payload: Data, name: String = "Ubuntu.txt") -> Data {
        let piece = Data(Insecure.SHA1.hash(data: payload))
        let info = Data("d6:lengthi\(payload.count)e4:name".utf8) + string(name)
            + Data("12:piece lengthi16384e6:pieces".utf8) + bytes(piece) + Data("e".utf8)
        return Data("d4:info".utf8) + info + Data("e".utf8)
    }

    static func withEngine(
        fake: TorrentFakeTransport = TorrentFakeTransport(),
        settings: TorrentEngineSettings = TorrentEngineSettings(),
        readyTimeout: Duration = .seconds(1),
        session: URLSession = URLSession(configuration: .ephemeral),
        body: (TorrentEngine, URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mulee-torrent-test-" + UUID().uuidString)
        let engine = TorrentEngine(
            stateDirectory: root, settings: settings, readyTimeout: readyTimeout,
            requestTimeout: .seconds(1), session: session, transportFactory: { fake }
        )
        do {
            try await body(engine, root)
            await engine.stop()
            if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        } catch {
            await engine.stop()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }
}
