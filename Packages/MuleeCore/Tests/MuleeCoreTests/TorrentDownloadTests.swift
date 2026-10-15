import Foundation
import Testing
@testable import MuleeCore

@Suite struct TorrentDownloadTests {
    @Test("远程种子下载到 incoming，发送绝对路径并清理临时文件")
    func remoteTorrent() async throws {
        let fake = TorrentFakeTransport()
        let session = TorrentURLProtocol.session()
        defer { session.invalidateAndCancel() }
        try await TorrentFixtures.withEngine(fake: fake, session: session) { engine, root in
            try await engine.start(options: EngineOptions(downloadDirectory: root))
            let url = try #require(URL(string: "https://torrent.invalid/Ubuntu.torrent"))
            _ = try await engine.add(link: .torrentFile(url: url, original: url.absoluteString), directory: root, filePriorities: [4])
            let request = try #require(await fake.sent.last)
            guard case .string(let path) = request.parameters["torrent_file"] else {
                Issue.record("应将远程种子转换成绝对文件路径")
                return
            }
            #expect(path.hasPrefix(root.appendingPathComponent("incoming").path + "/"))
            #expect(request.parameters["source"] == .string(url.absoluteString))
            #expect(await fake.addedTorrent == TorrentFixtures.torrent(payload: Data("Ubuntu".utf8)))
            #expect(!FileManager.default.fileExists(atPath: path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("incoming").path).isEmpty)
        }
    }

    @Test("远程种子同时校验声明大小与实际响应体大小", arguments: ["header-too-large.torrent", "body-too-large.torrent"])
    func sizeLimit(_ name: String) async throws {
        let fake = TorrentFakeTransport()
        let session = TorrentURLProtocol.session()
        defer { session.invalidateAndCancel() }
        try await TorrentFixtures.withEngine(fake: fake, session: session) { engine, root in
            try await engine.start(options: EngineOptions(downloadDirectory: root))
            let url = try #require(URL(string: "https://torrent.invalid/\(name)"))
            await #expect(throws: EngineError.invalidResponse("种子文件超过大小上限（20 MB）")) {
                try await engine.add(link: .torrentFile(url: url, original: url.absoluteString), directory: nil)
            }
            #expect(await fake.sent.map(\.method) == ["configure"])
        }
    }

    @Test("拒绝非 Bencode 字典和空内容", arguments: ["invalid.torrent", "empty.torrent"])
    func invalidPrefix(_ name: String) async throws {
        let fake = TorrentFakeTransport()
        let session = TorrentURLProtocol.session()
        defer { session.invalidateAndCancel() }
        try await TorrentFixtures.withEngine(fake: fake, session: session) { engine, root in
            try await engine.start(options: EngineOptions(downloadDirectory: root))
            let url = try #require(URL(string: "https://torrent.invalid/\(name)"))
            await #expect(throws: EngineError.self) {
                try await engine.add(link: .torrentFile(url: url, original: url.absoluteString), directory: nil)
            }
            #expect(await fake.sent.map(\.method) == ["configure"])
        }
    }
}
