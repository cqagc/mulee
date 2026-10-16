import Foundation
import Testing
@testable import MuleeCore

@Suite struct IncompleteHTTPTransferTests {
    @Test func stagingMovesAndPersistsAcrossRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let initial = IncompleteHTTPTransfer(taskID: id, destination: root)
        try initial.prepare()
        #expect(initial.directory == root.appendingPathComponent(".mulee-incomplete").appendingPathComponent(id.uuidString))
        let file = initial.directory.appendingPathComponent("sample.mp4")
        try Data("payload".utf8).write(to: file)
        var restored = try JSONDecoder().decode(IncompleteHTTPTransfer.self, from: JSONEncoder().encode(initial))
        #expect(restored.directory == initial.directory)
        try restored.planMove(from: file)
        restored = try JSONDecoder().decode(IncompleteHTTPTransfer.self, from: JSONEncoder().encode(restored))
        let target = try restored.finishMove(from: file)
        #expect(target == root.appendingPathComponent("sample.mp4"))
        #expect(try Data(contentsOf: target) == Data("payload".utf8))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        try restored.cleanup()
        #expect(!FileManager.default.fileExists(atPath: restored.directory.path))
        #expect(try restored.finishMove(from: file) == target)
    }

    @Test(arguments: [DownloadRequestContext.DuplicateAction.rename, .overwrite, .ask])
    func duplicatePolicy(action: DownloadRequestContext.DuplicateAction) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var transfer = IncompleteHTTPTransfer(taskID: UUID(), destination: root, duplicateAction: action)
        try transfer.prepare()
        let target = root.appendingPathComponent("sample.bin")
        try Data("old".utf8).write(to: target)
        let staged = transfer.directory.appendingPathComponent("sample.bin")
        try Data("new".utf8).write(to: staged)
        if action == .ask {
            #expect(throws: (any Error).self) { try transfer.planMove(from: staged) }
            #expect(try Data(contentsOf: target) == Data("old".utf8))
            #expect(FileManager.default.fileExists(atPath: staged.path))
        } else {
            try transfer.planMove(from: staged)
            let moved = try transfer.finishMove(from: staged)
            #expect(moved.lastPathComponent == (action == .rename ? "sample (1).bin" : "sample.bin"))
            #expect(try Data(contentsOf: moved) == Data("new".utf8))
            if action == .rename { #expect(try Data(contentsOf: target) == Data("old".utf8)) }
        }
    }

    @Test func lateCollisionDoesNotOverwriteAndRetryChoosesAnotherName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var transfer = IncompleteHTTPTransfer(taskID: UUID(), destination: root)
        try transfer.prepare()
        let staged = transfer.directory.appendingPathComponent("sample.bin")
        try Data("download".utf8).write(to: staged)
        try transfer.planMove(from: staged)
        let occupied = root.appendingPathComponent("sample.bin")
        try Data("other".utf8).write(to: occupied)
        #expect(throws: (any Error).self) { try transfer.finishMove(from: staged) }
        #expect(try Data(contentsOf: occupied) == Data("other".utf8))
        try transfer.planMove(from: staged)
        let moved = try transfer.finishMove(from: staged)
        #expect(moved.lastPathComponent == "sample (1).bin")
        #expect(try Data(contentsOf: moved) == Data("download".utf8))
    }

    @Test func interruptedMoveRecoversAndDeleteOnlyCleansOwnTask() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var transfer = IncompleteHTTPTransfer(taskID: UUID(), destination: root)
        let other = IncompleteHTTPTransfer(taskID: UUID(), destination: root)
        try transfer.prepare()
        try other.prepare()
        let staged = transfer.directory.appendingPathComponent("sample.zip")
        try Data([1, 2, 3]).write(to: staged)
        try transfer.planMove(from: staged)
        let saved = try JSONEncoder().encode(transfer)
        let completed = try transfer.finishMove(from: staged)
        var recovered = try JSONDecoder().decode(IncompleteHTTPTransfer.self, from: saved)
        #expect(try recovered.finishMove(from: staged) == completed)
        try recovered.cleanup()
        #expect(FileManager.default.fileExists(atPath: completed.path))
        #expect(FileManager.default.fileExists(atPath: other.directory.path))
        var fresh = IncompleteHTTPTransfer(taskID: UUID(), destination: root)
        #expect(throws: (any Error).self) { try fresh.planMove(from: root.appendingPathComponent("other.bin")) }
    }
}

@Suite(.serialized, .enabled(if: Aria2IntegrationFixture.binaryAvailable))
struct IncompleteHTTPIntegrationTests {
    @Test func pauseRestartReplaceAndFinalize() async throws {
        try await Aria2IntegrationFixture.withFixture { fixture in
            try await fixture.engine.start(options: fixture.options)
            let id = try await fixture.engine.add(
                link: fixture.link("slow-incomplete.bin"), directory: nil, context: .init(), incompleteTaskID: UUID()
            )
            let started = try await fixture.waitFor(id) { $0.receivedBytes > 131_072 }
            let file = try #require(started.savePath)
            #expect(IncompleteHTTPTransfer.isStagingFile(file))
            try await fixture.engine.pause(id)
            _ = try await fixture.waitFor(id) { $0.status == .paused }
            await fixture.engine.stop()
            try await fixture.engine.start(options: fixture.options)
            let restored = try await fixture.waitFor(id) { $0.status == .paused }
            #expect(restored.savePath == file)
            guard case .http(let url, _, _) = try fixture.link("replacement.bin") else { return }
            let replaced = try await fixture.engine.replaceURI(id, with: url, context: .init(), checksum: nil)
            try await fixture.engine.resume(replaced)
            let completed = try await fixture.waitFor(replaced) { $0.status == .completed }
            #expect(completed.savePath == file)
            await fixture.engine.stop()
            try await fixture.engine.start(options: fixture.options)
            #expect(try await fixture.engine.snapshots().first { $0.engineTaskID == replaced }?.savePath == file)
            let target = try await fixture.engine.finalizeIncomplete(replaced, file: file)
            #expect(target.deletingLastPathComponent().path == fixture.downloads.path)
            #expect(try Data(contentsOf: target) == fixture.payload)
            #expect(!FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
            #expect(try await fixture.engine.snapshots().first { $0.engineTaskID == replaced }?.savePath == target)
        }
    }

    @Test func deletionCleansIncompleteEvenWhenKeepingFilesAndLegacyPathIsUnchanged() async throws {
        try await Aria2IntegrationFixture.withFixture { fixture in
            try await fixture.engine.start(options: fixture.options)
            let id = try await fixture.engine.add(
                link: fixture.link("slow-delete.bin"), directory: nil, context: .init(), incompleteTaskID: UUID()
            )
            let active = try await fixture.waitFor(id) { $0.receivedBytes > 65_536 }
            let folder = try #require(active.savePath?.deletingLastPathComponent())
            try await fixture.engine.remove(id, deleteFiles: false)
            #expect(!FileManager.default.fileExists(atPath: folder.path))
            let legacyID = try await fixture.engine.add(link: fixture.link("legacy.bin"), directory: nil)
            let legacy = try await fixture.waitFor(legacyID) { $0.status == .completed }
            let legacyFile = try #require(legacy.savePath)
            #expect(legacyFile.deletingLastPathComponent().path == fixture.downloads.path)
            #expect(try await fixture.engine.finalizeIncomplete(legacyID, file: legacyFile) == legacyFile)
        }
    }
}
