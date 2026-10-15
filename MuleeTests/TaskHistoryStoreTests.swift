import Foundation
import MuleeCore
import Testing
@testable import Mulee

@Suite @MainActor struct TaskHistoryStoreTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "TaskHistory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func task(status: TaskStatus = .downloading) -> DownloadTask {
        DownloadTask(
            name: "雾港资料.zip", fileExtension: "zip", kind: .http, status: status,
            totalBytes: 100, receivedBytes: 25, downloadRate: 10, uploadRate: 2,
            estimatedTimeRemaining: .seconds(8),
            completedAt: status == .completed ? Date(timeIntervalSince1970: 1000) : nil,
            detail: .http(connections: 4),
            postDownload: PostDownloadInfo(autoExtract: true, matchedRuleName: "资料站", filenameEncoding: "Big5", extractProgress: 0.5),
            sourceLink: "https://example.com/archive.zip", engineTaskID: "gid",
            savePath: URL(filePath: "/tmp/下载/雾港资料.zip"),
            errorMessage: status == .failed ? "连接失败" : nil
        )
    }

    @Test func roundTripPreservesDurableFieldsAndAllDetails() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let details: [TaskDetail] = [
            .http(connections: 4),
            .bittorrent(fileCount: 8, selectedFileCount: 3, peerCount: 12, shareRatio: 0.5),
            .ed2k(hash: "ABC123", longTail: LongTailInfo(
                queueRank: 5, sourceCount: 3, completeSourceCount: 1,
                lastCompleteSourceSeen: Date(timeIntervalSince1970: 900),
                waitingSince: Date(timeIntervalSince1970: 800),
                activeTransferDuration: .seconds(60), dailySourceSightings: [1, 2, 3]
            )),
            .video(site: .bilibili, quality: "1080p", danmakuToASS: true)
        ]
        let kinds: [TaskKind] = [.http, .bittorrent, .ed2k, .video]
        let statuses: [TaskStatus] = [.completed, .failed, .engineUnavailable, .paused]
        let tasks = details.indices.map { index in
            var task = task(status: statuses[index])
            task.kind = kinds[index]
            task.detail = details[index]
            return task
        }
        let store = TaskHistoryStore(directory: directory)

        #expect(try store.flush(tasks: tasks))
        let result = TaskHistoryStore(directory: directory).load()

        #expect(result.issue == nil)
        #expect(result.tasks == TaskHistoryStore.durableTasks(tasks))
        #expect(result.tasks.map(\.id) == tasks.map(\.id))
        #expect(result.tasks.allSatisfy { $0.name == "雾港资料.zip" && $0.savePath == tasks[0].savePath })
        #expect(result.tasks.allSatisfy { $0.downloadRate == 0 && $0.uploadRate == 0 && $0.estimatedTimeRemaining == nil })
        #expect(result.tasks.allSatisfy { $0.postDownload.extractProgress == nil })
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        #expect(json["version"] as? Int == 1)
    }

    @Test func transientChangesAndLiveProgressDoNotWrite() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TaskHistoryStore(directory: directory)
        let original = task()
        #expect(try store.flush(tasks: [original]))
        let savedData = try Data(contentsOf: store.fileURL)
        let savedDate = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.modificationDate] as? Date
        var changed = original
        changed.downloadRate = 999
        changed.uploadRate = 555
        changed.estimatedTimeRemaining = .seconds(1)
        changed.receivedBytes = 99
        changed.detail = .http(connections: 16)
        changed.postDownload.extractProgress = 0.9

        #expect(!TaskHistoryStore.needsSave(tasks: [changed], lastSaved: [original]))
        #expect(try !store.flush(tasks: [changed]))
        #expect(try Data(contentsOf: store.fileURL) == savedData)
        #expect(try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.modificationDate] as? Date == savedDate)
        #expect(TaskHistoryStore(directory: directory).load().tasks.first?.receivedBytes == 0)
    }

    @Test func durableChangesRequireSaving() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = task()
        var status = original
        status.status = .completed
        status.receivedBytes = 100
        var name = original
        name.name = "确定的文件名.zip"
        var size = original
        size.totalBytes = 500
        var path = original
        path.savePath = URL(filePath: "/tmp/确定的路径.zip")
        var engineID = original
        engineID.engineTaskID = "restored-gid"

        for changed in [status, name, size, path, engineID] {
            #expect(TaskHistoryStore.needsSave(tasks: [changed], lastSaved: [original]))
        }
        #expect(TaskHistoryStore.needsSave(tasks: [], lastSaved: [original]))
        #expect(TaskHistoryStore.needsSave(tasks: [original, task()], lastSaved: [original]))
        let store = TaskHistoryStore(directory: directory)
        try store.flush(tasks: [original])
        #expect(try store.flush(tasks: [status]))
        #expect(TaskHistoryStore(directory: directory).load().tasks.first?.status == .completed)
        #expect(TaskHistoryStore(directory: directory).load().tasks.first?.receivedBytes == 100)
    }

    @Test func liveDetailStatisticsDoNotRequireSaving() {
        var bt = task()
        bt.detail = .bittorrent(fileCount: 5, selectedFileCount: 2, peerCount: 3, shareRatio: 0.5)
        var changedBT = bt
        changedBT.detail = .bittorrent(fileCount: 5, selectedFileCount: 2, peerCount: 9, shareRatio: 0.8)
        var ed2k = task()
        let longTail = LongTailInfo(
            queueRank: 1, sourceCount: 2, completeSourceCount: 1, lastCompleteSourceSeen: nil,
            waitingSince: Date(timeIntervalSince1970: 1000), activeTransferDuration: .seconds(1), dailySourceSightings: [1]
        )
        ed2k.detail = .ed2k(hash: "ABC", longTail: longTail)
        var changedED2K = ed2k
        var changedTail = longTail
        changedTail.queueRank = 10
        changedTail.sourceCount = 50
        changedTail.activeTransferDuration = .seconds(30)
        changedED2K.detail = .ed2k(hash: "ABC", longTail: changedTail)

        #expect(!TaskHistoryStore.needsSave(tasks: [changedBT, changedED2K], lastSaved: [bt, ed2k]))
    }

    @Test(arguments: ["损坏的 JSON", "{\"version\":999,\"tasks\":[]}"])
    func invalidHistoryIsBackedUpAndReported(_ contents: String) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TaskHistoryStore(directory: directory)
        let data = Data(contents.utf8)
        try data.write(to: store.fileURL)
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)

        model.loadTaskHistory(from: store)

        #expect(model.tasks.isEmpty)
        #expect(model.taskHistoryIssue?.contains("已备份") == true)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let backup = try #require(files.first { $0.lastPathComponent.hasPrefix("tasks.json.corrupt-") })
        #expect(try Data(contentsOf: backup) == data)
        model.tasks = [task(status: .failed)]
        model.flushTaskHistory()
        #expect(TaskHistoryStore(directory: directory).load().tasks == TaskHistoryStore.durableTasks(model.tasks))
    }

    @Test func missingFileStartsEmptyWithoutCreatingDirectory() throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appending(path: "not-created")
        let store = TaskHistoryStore(directory: directory)

        let result = store.load()

        #expect(result.tasks.isEmpty)
        #expect(result.issue == nil)
        #expect(try !store.flush(tasks: []))
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func debounceIgnoresRepeatedProgressAndFlushSavesLatestImmediately() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TaskHistoryStore(directory: directory)
        var current = task()
        store.scheduleSave(tasks: [current]) { Issue.record("\($0)") }
        try await Task.sleep(for: .milliseconds(1100))
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        current.receivedBytes = 80
        store.scheduleSave(tasks: [current]) { Issue.record("\($0)") }
        try await Task.sleep(for: .milliseconds(1200))
        #expect(TaskHistoryStore(directory: directory).load().tasks.count == 1)
        current.status = .failed
        current.errorMessage = "下载失败"
        store.scheduleSave(tasks: [current]) { Issue.record("\($0)") }

        #expect(try store.flush(tasks: [current]))
        #expect(TaskHistoryStore(directory: directory).load().tasks.first?.status == .failed)
        #expect(try !store.flush(tasks: [current]))
    }

    @Test func revertingPendingChangeCancelsWrite() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TaskHistoryStore(directory: directory)
        _ = store.load()
        store.scheduleSave(tasks: [task()]) { Issue.record("\($0)") }
        store.scheduleSave(tasks: []) { Issue.record("\($0)") }

        try await Task.sleep(for: .milliseconds(2200))

        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test func flushFailureIsRecordedInSystemStatus() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocked = directory.appending(path: "file-not-directory")
        try Data().write(to: blocked)
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        model.loadTaskHistory(from: TaskHistoryStore(directory: blocked))
        model.tasks = [task()]

        model.flushTaskHistory()

        #expect(model.taskHistoryIssue?.contains("无法保存任务历史") == true)
    }

    @Test func sampleDataAndTestHostDoNotAttachRealHistory() {
        let model = AppModel(tasks: [task()], preventsSleepWhileDownloading: false)
        let original = model.tasks
        let delegate = AppDelegate()
        #expect(AppEnvironment.isRunningUnitTests)

        delegate.configure(model: model, settings: SettingsModel(), usesSampleData: true)
        delegate.configure(model: model, settings: SettingsModel(), usesSampleData: false)
        model.flushTaskHistory()

        #expect(model.tasks == original)
        #expect(model.taskHistoryIssue == nil)
        #expect(model.coordinator == nil)
    }
}
