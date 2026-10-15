import Foundation
import MuleeCore
import Testing
@testable import Mulee

@Suite @MainActor struct ExtractionIntegrationTests {
    nonisolated private static var binary: URL? {
        ["/opt/homebrew/bin/7zz", "/usr/local/bin/7zz"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }.map { URL(filePath: $0) }
    }

    @Test(.enabled(if: Self.binary != nil, "本机没有 7zz，跳过集成测试"))
    func extractsEncryptedArchiveAfterTaskCompletes() async throws {
        let binary = try #require(Self.binary)
        let context = try ExtractionTestContext()
        let payload = context.root.appendingPathComponent("繁體資源.txt")
        let content = Data("虛構星雲遊戲資料".utf8)
        try content.write(to: payload)
        let archive = context.root.appendingPathComponent("星雲.7z")
        try await Self.createArchive(binary: binary, archive: archive, payload: payload)
        try FileManager.default.removeItem(at: payload)
        let rule = UnzipRule(matchKind: .sourceSite, pattern: "files.example.com", keychainItemID: "integration", maskedLength: 16, hitCount: 0)
        context.model.unzipRules = [rule]
        let service = ArchiveExtractionService(
            binary: binary, passwords: InMemoryPasswordProvider(passwords: ["integration": "integration-only"])
        )
        let coordinator = ExtractionCoordinator(model: context.model, settings: context.settings, extractor: service)
        context.model.tasks = [try context.task("星雲.7z", createFile: false)]
        coordinator.start()
        context.model.tasks[0].status = .completed
        try await context.waitUntil { context.model.tasks[0].postDownload.extractionState == .succeeded }

        #expect(try Data(contentsOf: payload) == content)
        #expect(context.model.tasks[0].status == .completed)
        #expect(context.model.tasks[0].postDownload.extractedItems == [payload])
        #expect(context.model.tasks[0].postDownload.filenameEncoding == "UTF-8")
        #expect(context.model.tasks[0].postDownload.matchedRuleName == rule.pattern)
        #expect(context.model.unzipRules[0].hitCount == 1)
        #expect(FileManager.default.fileExists(atPath: archive.path))
        await coordinator.stop()
        try await context.clean()
    }

    @concurrent
    nonisolated private static func createArchive(binary: URL, archive: URL, payload: URL) async throws {
        let process = Process()
        process.executableURL = binary
        process.currentDirectoryURL = payload.deletingLastPathComponent()
        process.arguments = ["a", "-t7z", "-pintegration-only", "-mhe=on", archive.path, payload.lastPathComponent]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() }
            catch { continuation.resume(throwing: error) }
        }
        #expect(status == 0, "7zz 未能生成加密测试压缩包")
    }
}
