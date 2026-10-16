import Foundation
import MuleeCore
import Testing
@testable import Mulee

@Suite @MainActor struct TaskTrashTests {
    @Test(arguments: [false, true])
    func trashedTorrentIsADuplicateForMagnetAndLocalFile(localFile: Bool) async throws {
        let defaults = try TemporaryDefaults(prefix: "TrashDuplicate-")
        defer { defaults.clean() }
        let settings = SettingsModel(defaults: defaults.defaults)
        settings.diskReserveEnabled = false
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture.torrent")
        let data = Data("d4:infod6:lengthi1e4:name7:fixture12:piece lengthi16384e6:pieces20:aaaaaaaaaaaaaaaaaaaaee".utf8)
        try data.write(to: file)
        let hash = try TorrentFileInfo.parse(data: data).infoHash
        let magnet = try #require(LinkParser.parse("magnet:?xt=urn:btih:\(hash)").first)
        let link = localFile ? ParsedLink.torrentFile(url: file, original: file.absoluteString) : magnet
        var task = DownloadTask(link: link, autoExtract: false)
        task.engineTaskID = localFile ? nil : hash.uppercased()
        task.deletedAt = .now
        let model = AppModel(tasks: [task], preventsSleepWhileDownloading: false)
        let draft = NewTaskModel(inputText: link.original)
        #expect(await draft.checkBeforeAdding(in: model, settings: settings) == false)
        let item = try #require(draft.links.first)
        #expect(item.duplicateMessage == "这个种子已在最近删除里，请恢复任务，或彻底删除后再添加。")
        #expect(item.canMergeTrackers == false)
        let engine = FakeEngine(kind: .bittorrent)
        let coordinator = DownloadCoordinator(model: model, engines: [engine])
        await coordinator.start(options: EngineOptions(downloadDirectory: URL(filePath: "/tmp")))
        await coordinator.add(links: [link], autoExtract: false)
        #expect(await engine.addedLinks.isEmpty)
        #expect(model.tasks.count == 1)
        #expect(model.openURLIssue == item.duplicateMessage)
        await coordinator.stop()
    }

    @Test func readdedTorrentClearsStartupSnapshotExclusion() async throws {
        let hash = String(repeating: "a", count: 40)
        let link = try #require(LinkParser.parse("magnet:?xt=urn:btih:\(hash)").first)
        var task = DownloadTask(link: link, autoExtract: false)
        task.engineTaskID = "task-1"
        task.deletedAt = .now
        let model = AppModel(tasks: [task], preventsSleepWhileDownloading: false)
        let engine = FakeEngine(kind: .bittorrent)
        let coordinator = DownloadCoordinator(model: model, engines: [engine])
        await coordinator.start(options: EngineOptions(downloadDirectory: URL(filePath: "/tmp")))
        model.removeRecord(task.id)
        await coordinator.add(links: [link], autoExtract: false)
        await engine.setSnapshots([EngineTaskSnapshot(
            engineTaskID: "task-1", name: "readded", totalBytes: 100, receivedBytes: 20,
            downloadRate: 10, uploadRate: 0, status: .downloading, connections: 1,
            savePath: nil, sourceURL: nil, errorMessage: nil
        )])
        await coordinator.poll()
        #expect(model.tasks.count == 1)
        #expect(model.tasks.first?.receivedBytes == 20)
        #expect(model.tasks.first?.status == .downloading)
        await coordinator.stop()
    }

    @Test func deletionRestoreAndExpirationKeepFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("file.zip")
        try Data([1]).write(to: file)
        var task = MockData.longTailTask
        task.savePath = file
        task.status = .completed
        let model = AppModel(tasks: [task], preventsSleepWhileDownloading: false)
        let now = Date(timeIntervalSince1970: 100_000)
        model.trashRecord(task.id, now: now)
        #expect(model.activeTasks.isEmpty)
        #expect(model.tasks.count == 1)
        #expect(!model.hasCompletedTasks)
        #expect(!TaskTrash.isExpired(model.tasks[0], now: now.addingTimeInterval(TaskTrash.retention - 1)))
        #expect(TaskTrash.isExpired(model.tasks[0], now: now.addingTimeInterval(TaskTrash.retention)))
        model.restoreRecord(task.id)
        #expect(model.activeTasks.count == 1)
        #expect(model.tasks[0].status == .completed)
        model.trashRecord(task.id, now: now)
        model.purgeExpiredTrash(now: now.addingTimeInterval(TaskTrash.retention))
        #expect(model.tasks.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func trashedTasksDoNotCountAsTransfersOrRates() {
        var task = MockData.longTailTask
        task.status = .downloading
        task.downloadRate = 100
        task.uploadRate = 10
        let model = AppModel(tasks: [task], preventsSleepWhileDownloading: false)
        model.trashRecord(task.id)
        #expect(!model.hasActiveTransfers)
        #expect(model.totalDownloadRate == 0)
        #expect(model.totalUploadRate == 0)
        model.restoreRecord(task.id)
        #expect(model.tasks[0].status == .paused)
    }

    @Test func trashIsExcludedFromProtectionNotificationsActionsAndMenuBar() async throws {
        let defaults = try TemporaryDefaults(prefix: "TaskTrash-")
        defer { defaults.clean() }
        let settings = SettingsModel(defaults: defaults.defaults)
        var task = MockData.longTailTask
        task.status = .downloading
        task.deletedAt = .now
        let model = AppModel(tasks: [task], preventsSleepWhileDownloading: false)
        let center = DownloadNotificationCenterSpy()
        var now = Date(timeIntervalSince1970: 0)
        let notifications = NotificationService(model: model, settings: settings, center: center, now: { now })
        let controller = WhenAllDoneController(model: model, settings: settings, showsPanel: false) { _ in
            Issue.record("回收站任务不能触发下完后动作")
        }
        controller.select(.quit)
        let monitor = DiskReserveMonitor(model: model, settings: settings, volume: { $0 }) { _ in
            Issue.record("回收站任务不能参与磁盘保护")
            return 0
        }
        await monitor.refresh()
        model.tasks[0].status = .completed
        now += 10
        notifications.flushCompletionsIfDue()
        await notifications.waitForDelivery()
        #expect(center.requests.isEmpty)
        #expect(model.whenAllDoneSecondsRemaining == nil)
        #expect(model.diskReserveWarnings.isEmpty)
        #expect(MenuBarPresentation(tasks: model.tasks).isEmpty)
    }

    @Test func pendingCompletionIsSuppressedAfterTrashing() async throws {
        let defaults = try TemporaryDefaults(prefix: "TaskTrashPending-")
        defer { defaults.clean() }
        let settings = SettingsModel(defaults: defaults.defaults)
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        let center = DownloadNotificationCenterSpy()
        var now = Date(timeIntervalSince1970: 0)
        let notifications = NotificationService(model: model, settings: settings, center: center, now: { now })
        var task = MockData.longTailTask
        task.status = .completed
        model.tasks = [task]
        model.trashRecord(task.id)
        now += 10
        notifications.flushCompletionsIfDue()
        await notifications.waitForDelivery()
        #expect(center.requests.isEmpty)
        model.removeRecord(task.id)
        #expect(model.tasks.isEmpty)
    }

    @Test(arguments: [TaskKind.http, .bittorrent, .ed2k])
    func restoredUnfinishedTaskResubmitsOriginalSource(kind: TaskKind) async throws {
        let source: String = switch kind {
        case .bittorrent: "magnet:?xt=urn:btih:0123456789012345678901234567890123456789"
        case .ed2k: "ed2k://|file|fixture.bin|100|01234567890123456789012345678901|/"
        default: "https://example.com/fixture.bin"
        }
        let link = try #require(LinkParser.parse(source).first)
        var task = DownloadTask(link: link, autoExtract: false)
        task.engineTaskID = "removed-engine-task"
        task.status = .downloading
        task.savePath = URL(filePath: "/tmp/restored-downloads/fixture.bin")
        let model = AppModel(tasks: [task], preventsSleepWhileDownloading: false)
        let engine = FakeEngine(kind: kind)
        let coordinator = DownloadCoordinator(model: model, engines: [engine])
        await coordinator.start(options: EngineOptions(downloadDirectory: URL(filePath: "/tmp/default-downloads")))
        await coordinator.remove(task.id)
        model.restoreRecord(task.id)
        #expect(model.tasks[0].engineTaskID == nil)
        #expect(model.tasks[0].status == .paused)

        await coordinator.resume(task.id)

        #expect(await engine.addedLinks == [link])
        #expect(await engine.directories == [task.savePath?.deletingLastPathComponent()])
        #expect(model.tasks.count == 1)
        #expect(model.tasks[0].id == task.id)
        #expect(model.tasks[0].engineTaskID == "task-1")
        #expect(await engine.resumedIDs == ["task-1"])
        await coordinator.stop()
    }

    @Test func restoredStagingFileUsesOriginalDestinationAndKeepsPartialData() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = try #require(LinkParser.parse("https://example.com/fixture.bin").first)
        var task = DownloadTask(link: link, autoExtract: false)
        let transfer = IncompleteHTTPTransfer(taskID: task.id, destination: directory)
        try transfer.prepare()
        let file = transfer.directory.appendingPathComponent("fixture.bin")
        let control = file.appendingPathExtension("aria2")
        let partial = Data("retained partial data".utf8)
        try partial.write(to: file)
        try Data("retained control data".utf8).write(to: control)
        task.savePath = file
        task.receivedBytes = Int64(partial.count)
        task.status = .paused
        task.deletedAt = .now
        let model = AppModel(tasks: [task], preventsSleepWhileDownloading: false)
        let engine = FakeEngine()
        let coordinator = DownloadCoordinator(model: model, engines: [engine])
        await coordinator.start(options: EngineOptions(downloadDirectory: directory.appendingPathComponent("other")))
        model.restoreRecord(task.id)

        await coordinator.resume(task.id)

        let directories = await engine.directories
        #expect(directories.map { $0?.standardizedFileURL.path } == [directory.standardizedFileURL.path])
        #expect(model.tasks[0].id == task.id)
        #expect(model.tasks[0].savePath == file)
        #expect(try Data(contentsOf: file) == partial)
        #expect(FileManager.default.fileExists(atPath: control.path))
        await coordinator.stop()
    }

    @Test func restoredLocalTorrentResubmitsOriginalFile() async throws {
        let file = URL(filePath: "/tmp/fixture.torrent")
        let link = ParsedLink.torrentFile(url: file, original: file.absoluteString)
        var task = DownloadTask(link: link, autoExtract: false)
        task.status = .paused
        task.deletedAt = .now
        let model = AppModel(tasks: [task], preventsSleepWhileDownloading: false)
        let engine = FakeEngine(kind: .bittorrent)
        let coordinator = DownloadCoordinator(model: model, engines: [engine])
        await coordinator.start(options: EngineOptions(downloadDirectory: URL(filePath: "/tmp/downloads")))
        model.restoreRecord(task.id)

        await coordinator.resume(task.id)

        #expect(await engine.addedLinks == [link])
        #expect(model.tasks[0].engineTaskID != nil)
        await coordinator.stop()
    }

    @Test func restoredTaskSubmissionFailureRemainsPausedWithRecoveryMessage() async throws {
        let link = try #require(LinkParser.parse("https://example.com/fixture.bin").first)
        var task = DownloadTask(link: link, autoExtract: false)
        task.status = .paused
        task.deletedAt = .now
        let model = AppModel(tasks: [task], preventsSleepWhileDownloading: false)
        let engine = FakeEngine()
        let coordinator = DownloadCoordinator(model: model, engines: [engine])
        await coordinator.start(options: EngineOptions(downloadDirectory: URL(filePath: "/tmp/downloads")))
        model.restoreRecord(task.id)
        await engine.failOperations(with: .notRunning)

        await coordinator.resume(task.id)

        #expect(model.tasks[0].status == .paused)
        #expect(model.tasks[0].engineTaskID == nil)
        #expect(model.tasks[0].errorMessage?.contains("未能恢复下载") == true)
        #expect(model.tasks[0].errorMessage?.contains("重试") == true)
        await coordinator.stop()
    }

    @Test func restoredHTTPCompletionKeepsIdentityWhenSessionReturns() {
        var task = MockData.longTailTask
        task.kind = .http
        task.status = .completed
        task.engineTaskID = "completed-file"
        let model = AppModel(tasks: [task], preventsSleepWhileDownloading: false)
        model.trashRecord(task.id)
        model.restoreRecord(task.id)
        let snapshot = EngineTaskSnapshot(
            engineTaskID: "completed-file", name: "file.zip", totalBytes: 100, receivedBytes: 100,
            downloadRate: 0, uploadRate: 0, status: .completed, connections: 0,
            savePath: nil, sourceURL: nil, errorMessage: nil
        )
        let merged = EngineSnapshotMerger.merge(tasks: model.tasks, snapshots: [.http: [snapshot]], now: .now)
        #expect(merged.count == 1)
        #expect(merged.first?.id == task.id)
    }
}
