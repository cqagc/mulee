import Foundation
import MuleeCore
import Testing
@testable import Mulee

@Suite @MainActor struct EngineSnapshotMergerTests {
    private func snapshot(
        id: String = "gid", status: TaskStatus = .downloading,
        total: Int64? = 100, received: Int64 = 25, rate: Int64 = 5
    ) -> EngineTaskSnapshot {
        EngineTaskSnapshot(
            engineTaskID: id, name: "download.zip", totalBytes: total,
            receivedBytes: received, downloadRate: rate, uploadRate: 2,
            status: status, connections: 4,
            savePath: URL(filePath: "/tmp/download.zip"),
            sourceURL: URL(string: "https://example.com/download.zip"),
            errorMessage: status == .failed ? "连接失败" : nil
        )
    }

    @Test func restoredSnapshotCreatesRealTask() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let current = snapshot()

        let result = EngineSnapshotMerger.merge(tasks: [], snapshots: [.http: [current]], now: now)

        let task = try #require(result.first)
        #expect(task.name == current.name)
        #expect(task.kind == .http)
        #expect(task.fileExtension == "zip")
        #expect(task.engineTaskID == "gid")
        #expect(task.totalBytes == 100)
        #expect(task.receivedBytes == 25)
        #expect(task.fractionCompleted == 0.25)
        #expect(task.downloadRate == 5)
        #expect(task.uploadRate == 2)
        #expect(task.status == .downloading)
        #expect(task.savePath == current.savePath)
        #expect(task.sourceLink == current.sourceURL?.absoluteString)
        #expect(task.detail == .http(connections: 4))
        #expect(task.estimatedTimeRemaining == .seconds(15))
        #expect(task.completedAt == nil)
    }

    @Test func updatePreservesIdentityAndRecordsFirstCompletion() throws {
        var existing = MockData.tasks[0]
        existing.kind = .http
        existing.engineTaskID = "gid"
        existing.completedAt = nil
        existing.postDownload.autoExtract = true
        let firstCompletion = Date(timeIntervalSince1970: 1000)

        let completed = EngineSnapshotMerger.merge(
            tasks: [existing], snapshots: [.http: [snapshot(status: .completed, received: 100, rate: 0)]],
            now: firstCompletion
        )
        let repeated = EngineSnapshotMerger.merge(
            tasks: completed, snapshots: [.http: [snapshot(status: .completed, received: 100, rate: 0)]],
            now: firstCompletion.addingTimeInterval(60)
        )

        let task = try #require(repeated.first)
        #expect(task.id == existing.id)
        #expect(task.postDownload.autoExtract)
        #expect(task.name == "download.zip")
        #expect(task.completedAt == firstCompletion)
        #expect(task.estimatedTimeRemaining == nil)
    }

    @Test func missingTaskOnlyFailsForSuccessfullyPolledEngineAndKeepsLocalTasks() {
        var http = MockData.tasks[0]
        http.kind = .http
        http.engineTaskID = "same-id"
        http.status = .downloading
        var bt = http
        bt.kind = .bittorrent
        let local = MockData.longTailTask

        let result = EngineSnapshotMerger.merge(tasks: [http, bt, local], snapshots: [.http: []], now: .now)

        #expect(result.count == 3)
        #expect(result.first { $0.kind == .http }?.status == .failed)
        #expect(result.contains { $0.kind == .bittorrent && $0.engineTaskID == "same-id" })
        #expect(result.contains { $0.id == local.id })
    }

    @Test func matchingIncludesKindAndReplacesErrors() throws {
        let snapshots = [snapshot(status: .failed)]
        let failed = EngineSnapshotMerger.merge(tasks: [], snapshots: [.http: snapshots, .bittorrent: snapshots], now: .now)
        #expect(failed.count == 2)
        #expect(failed.allSatisfy { $0.errorMessage == "连接失败" })

        let resumed = EngineSnapshotMerger.merge(tasks: failed, snapshots: [.http: [snapshot()]], now: .now)

        #expect(resumed.count == 2)
        #expect(try #require(resumed.first { $0.kind == .http }).errorMessage == nil)
        #expect(resumed.first { $0.kind == .bittorrent }?.errorMessage == "连接失败")
    }

    @Test("未知大小、零速度、暂停均不推测剩余时间", arguments: [
        (nil as Int64?, Int64(5), TaskStatus.downloading),
        (100 as Int64?, Int64(0), TaskStatus.downloading),
        (100 as Int64?, Int64(5), TaskStatus.paused)
    ])
    func unknownRemainingTime(_ total: Int64?, _ rate: Int64, _ status: TaskStatus) {
        let result = EngineSnapshotMerger.merge(
            tasks: [], snapshots: [.http: [snapshot(status: status, total: total, rate: rate)]], now: .now
        )

        #expect(result.first?.estimatedTimeRemaining == nil)
    }

    @Test func historyRetainsNewestThirtySamples() {
        let result = EngineSnapshotMerger.appendingRate(40, to: Array(0..<40).map(Int64.init))

        #expect(result == Array(11...40).map(Int64.init))
    }

    @Test func unavailableNetworkAndEngineHaveHonestLabels() {
        let network = NetworkStatus(
            ed2kID: .disconnected, kad: .disconnected, bittorrentPortReachable: nil,
            p2pRoutedThroughProxy: false, p2pExitIP: nil, portMappingSucceeded: nil
        )

        #expect(EngineStatusPresentation.ed2k(network.ed2kID) == "未启用")
        #expect(EngineStatusPresentation.kad(network.kad) == "未启用")
        #expect(EngineStatusPresentation.port(network.bittorrentPortReachable) == "未启用")
        #expect(EngineStatusPresentation.exit(network) == "未检测")
        #expect(EngineStatusPresentation.title(for: .running) == "HTTP 就绪")
        #expect(EngineStatusPresentation.title(for: .unavailable) == "未接入")
    }

    @Test func finderURLPrefersEngineSavePath() {
        var task = MockData.tasks[0]
        let actualPath = URL(filePath: "/tmp/custom/file.zip")
        task.savePath = actualPath

        #expect(TaskActions.localURL(for: task) == actualPath)
        task.savePath = nil
        #expect(TaskActions.localURL(for: task) == URL.downloadsDirectory.appending(path: "Mulee").appending(path: task.name))
    }
}
