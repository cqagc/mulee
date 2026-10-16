import Foundation
import Testing
@testable import MuleeCore

@Suite struct IncompleteTorrentAPITests {
    @Test func newTaskMarkerAndStreamingParameters() async throws {
        let transport = TorrentFakeTransport()
        try await TorrentFixtures.withEngine(fake: transport) { engine, directory in
            try await engine.start(options: EngineOptions(downloadDirectory: directory))
            let link = try #require(LinkParser.parse("magnet:?xt=urn:btih:\(TorrentFixtures.id)").first)
            _ = try await engine.add(link: link, directory: directory, filePriorities: nil, markIncomplete: false)
            #expect(await transport.sent.last?.parameters["mark_incomplete"] == .bool(false))
            try await engine.setStreaming(TorrentFixtures.id, fileIndex: 3, enabled: true)
            #expect(await transport.sent.last?.method == "set_streaming")
            #expect(await transport.sent.last?.parameters == [
                "id": .string(TorrentFixtures.id), "file_index": .integer(3), "enabled": .bool(true)
            ])
            try await engine.setStreaming(TorrentFixtures.id, fileIndex: 3, enabled: false)
            #expect(await transport.sent.last?.parameters["enabled"] == .bool(false))
        }
    }

    @Test func fileProgressDecodesNewAndLegacyProtocol() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let legacy = Data("""
            {"index":0,"path":"sample.mp4","size":100,"done":20,"priority":4}
            """.utf8)
        let old = try decoder.decode(TorrentFileEntry.self, from: legacy)
        #expect(old.storagePath == nil && old.contiguousDone == nil)
        let modern = Data("""
            {"index":0,"path":"sample.mp4","size":100,"done":20,"priority":4,
             "storage_path":"sample.mp4.mulee","contiguous_done":5}
            """.utf8)
        let current = try decoder.decode(TorrentFileEntry.self, from: modern)
        #expect(current.storagePath == "sample.mp4.mulee" && current.contiguousDone == 5)
    }
}
