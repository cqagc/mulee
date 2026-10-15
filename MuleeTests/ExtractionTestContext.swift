import Foundation
import MuleeCore
import Testing
@testable import Mulee

@MainActor
final class ExtractionTestContext {
    let root: URL
    let defaults: UserDefaults
    let suiteName: String
    let settings: SettingsModel
    let model: AppModel
    let extractor: ExtractionFakeExtractor
    let coordinator: ExtractionCoordinator

    init(suspends: Bool = false, outcome: ExtractionOutcome = ExtractionOutcome(status: .succeeded)) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MuleeAppExtraction-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "MuleeAppExtraction-" + UUID().uuidString
        defaults = try #require(UserDefaults(suiteName: suiteName))
        settings = SettingsModel(defaults: defaults)
        settings.originalAction = .keep
        settings.saveDirectory = root.path
        model = AppModel(tasks: [], unzipRules: [], preventsSleepWhileDownloading: false)
        model.extractionPasswords = ExtractionMemoryPasswords()
        extractor = ExtractionFakeExtractor(suspends: suspends, outcome: outcome)
        coordinator = ExtractionCoordinator(model: model, settings: settings, extractor: extractor)
    }

    func task(_ name: String = "资料.zip", status: TaskStatus = .downloading, autoExtract: Bool = true, createFile: Bool = true) throws -> DownloadTask {
        let path = root.appendingPathComponent(name)
        if createFile { try Data("原压缩包".utf8).write(to: path) }
        return DownloadTask(
            name: name, fileExtension: path.pathExtension, kind: .http, status: status,
            totalBytes: 100, receivedBytes: 100, completedAt: status == .completed ? .now : nil,
            detail: .http(connections: 0), postDownload: PostDownloadInfo(autoExtract: autoExtract),
            sourceLink: "https://files.example.com/" + name, engineTaskID: UUID().uuidString, savePath: path
        )
    }

    func waitUntil(_ predicate: () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !(await predicate()), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await predicate(), "解压状态未在时限内到达预期值")
    }

    func clean() async throws {
        await coordinator.stop()
        defaults.removePersistentDomain(forName: suiteName)
        try FileManager.default.removeItem(at: root)
    }
}
