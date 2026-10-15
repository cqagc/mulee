import Foundation
import Testing
@testable import MuleeCore

struct YtDlpRetryTests {
    @Test(arguments: ["Unable to extract player response", "HTTP Error 403: Forbidden"])
    func downloadFailureUpdatesAndRetriesExactlyOnce(raw: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("YtDlp-retry-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("yt-dlp")
        let marker = root.appendingPathComponent("updated")
        try Data("#!/bin/sh\necho 'ERROR: \(raw)' >&2\nexit 1\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let engine = YtDlpEngine(
            stateDirectory: root.appendingPathComponent("state"), binaryURL: binary, installer: nil,
            updater: {
                // 第二次调用会失败，确保引擎不会无限更新重试。
                guard !FileManager.default.fileExists(atPath: marker.path) else {
                    throw EngineError.invalidResponse("重复更新")
                }
                try Data("updated".utf8).write(to: marker)
                return binary
            }
        )
        do {
            try await engine.start(options: EngineOptions(downloadDirectory: root.appendingPathComponent("downloads")))
            let url = try #require(URL(string: "https://example.invalid/test"))
            let id = try await engine.add(link: .video(url: url, site: .other, original: url.absoluteString))
            let failed = try await YtDlpIntegrationFixture.waitFor(engine, id: id) { $0.status == .failed }
            #expect(failed.errorMessage?.contains(raw) == true)
            #expect(FileManager.default.fileExists(atPath: marker.path))
            #expect(failed.errorMessage?.contains("重复更新") == false)
            await engine.stop()
        } catch {
            await engine.stop()
            throw error
        }
    }
}
