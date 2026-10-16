import Foundation
import MuleeCore
import Testing
@testable import Mulee

@Suite @MainActor struct Ed2kWiringTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let hash = "0123456789ABCDEF0123456789ABCDEF"
    private let options = EngineOptions(downloadDirectory: URL(filePath: "/tmp/Mulee"))

    private var link: ParsedLink {
        .ed2k(fileName: "Ubuntu.zip", size: 100, hash: hash,
              original: "ed2k://|file|Ubuntu.zip|100|\(hash)|/")
    }

    private var longTail: LongTailInfo {
        LongTailInfo(
            queueRank: 17, sourceCount: 4, completeSourceCount: 2,
            lastCompleteSourceSeen: now.addingTimeInterval(-2 * 86400),
            waitingSince: now.addingTimeInterval(-12 * 86400),
            activeTransferDuration: .seconds(7200),
            dailySourceSightings: Array(repeating: 0, count: 13) + [4]
        )
    }

    private func snapshot(id: String = "task-1", status: TaskStatus = .waitingForSources, path: URL? = nil) -> EngineTaskSnapshot {
        EngineTaskSnapshot(
            engineTaskID: id, name: "Ubuntu.zip", totalBytes: 100,
            receivedBytes: status == .completed ? 100 : 40,
            downloadRate: 0, uploadRate: 0, status: status, connections: 0,
            savePath: path ?? options.downloadDirectory.appending(path: "Ubuntu.zip"),
            sourceURL: URL(string: link.original), errorMessage: nil,
            detail: .ed2k(hash: hash, longTail: longTail), completedAt: status == .completed ? now : nil
        )
    }

    @Test("电驴设置使用用户值，目录与限速采用十进制单位，设置能够持久保存")
    func settingsMapping() throws {
        let temporaryDefaults = try TemporaryDefaults(prefix: "Ed2kWiringTests.")
        defer { temporaryDefaults.clean() }
        let defaults = temporaryDefaults.defaults
        let settings = SettingsModel(defaults: defaults)
        #expect(settings.ed2kConnectToServers && settings.ed2kEnableKad)
        settings.ed2kTCPPort = 40123
        settings.ed2kUDPPort = 40124
        settings.ed2kConnectToServers = false
        settings.ed2kEnableKad = false
        settings.ed2kShare = false
        settings.ed2kObfuscation = false
        settings.saveDirectory = "/tmp/Mulee 电驴"
        settings.downloadLimit = 5
        settings.uploadLimit = 0.5

        let configuration = Ed2kEngineConfiguration.configuration(from: settings)
        let restored = SettingsModel(defaults: defaults)
        let options = EngineOptionsMapper.options(from: settings)

        #expect(configuration.tcpPort == 40123 && configuration.udpPort == 40124)
        #expect(!configuration.connectToServers && !configuration.enableKad)
        #expect(!configuration.shareCompletedFiles && !configuration.obfuscation)
        #expect(configuration.uploadLimit == 0)
        #expect(options.downloadLimit == 5_000_000 && options.uploadLimit == 500_000)
        #expect(options.downloadDirectory.path == settings.saveDirectory)
        #expect(Ed2kEngineConfiguration.configuration(from: restored) == configuration)
        settings.ed2kTCPPort = -1
        settings.ed2kUDPPort = 100_000
        #expect(Ed2kEngineConfiguration.configuration(from: settings).tcpPort == 1)
        #expect(Ed2kEngineConfiguration.configuration(from: settings).udpPort == 65535)
        settings.uploadLimit = 0
        #expect(Ed2kEngineConfiguration.configuration(from: settings).uploadLimit == 0)
    }

    @Test("电驴和 Kad 更新及断开不覆盖 BT、出口与端口映射", arguments: [NetworkStatus.Ed2kID.high, .low, .disconnected], [NetworkStatus.KadState.open, .firewalled, .disconnected])
    func networkUpdates(id: NetworkStatus.Ed2kID, kad: NetworkStatus.KadState) {
        let original = NetworkStatus(
            ed2kID: .disconnected, kad: .disconnected, bittorrentPortReachable: true,
            p2pRoutedThroughProxy: true, p2pExitIP: "203.0.113.8", portMappingSucceeded: false
        )
        let model = AppModel(tasks: [], networkStatus: original, preventsSleepWhileDownloading: false)

        model.updateEd2kNetworkStatus(id: id, kad: kad)

        var expected = original
        expected.ed2kID = id
        expected.kad = kad
        #expect(model.networkStatus == expected)
        #expect(EngineStatusPresentation.ed2k(id) == (id == .high ? "可连入" : id == .low ? "连入受限" : "未连接"))
        #expect(EngineStatusPresentation.kad(kad) == (kad == .open ? "开放" : kad == .firewalled ? "受限" : "未连接"))
    }

    @Test("长尾快照呈现真实排队、完整来源、等待与累计时长，等待不算失败")
    func longTailPresentation() throws {
        let task = try #require(EngineSnapshotMerger.merge(tasks: [], snapshots: [.ed2k: [snapshot()]], now: now).first)
        let presentation = TaskPresentation(task: task, now: now)

        #expect(presentation.longTail == longTail)
        #expect(presentation.longTailStatus == "排队中，第 17 位")
        #expect(presentation.sourceSummary == "4 个（2 个完整）")
        #expect(presentation.lastCompleteSource == "2 天前")
        #expect(presentation.waitingDuration == "12 天")
        #expect(presentation.transferDuration.contains("2 小时"))
        #expect(presentation.statusTitle == "等待来源")
        #expect(presentation.statusSubtitle == "已挂 12 天")
        #expect(presentation.progressStyle == .waiting)
        #expect(task.errorMessage == nil)
        var empty = task
        var info = longTail
        info.queueRank = nil
        info.sourceCount = 0
        info.completeSourceCount = 0
        info.lastCompleteSourceSeen = nil
        empty.detail = .ed2k(hash: hash, longTail: info)
        let waiting = TaskPresentation(task: empty, now: now)
        #expect(waiting.longTailStatus == "等待来源")
        #expect(waiting.lastCompleteSource == "尚未见到")
        #expect(waiting.metadata.contains("暂无来源，尚未见到完整源"))
        empty.status = .downloading
        empty.downloadRate = 10
        #expect(TaskPresentation(task: empty).longTailStatus == "正在下载")
    }

    @Test("电驴路由、设置下发、暂停继续与删除文件选项均交给电驴引擎", arguments: [false, true])
    func routing(deleteFiles: Bool) async throws {
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        let ed2k = FakeEngine(kind: .ed2k)
        let http = FakeEngine(startError: .binaryNotFound)
        let coordinator = DownloadCoordinator(model: model, engines: [http, ed2k])
        await coordinator.start(options: options)
        let directory = options.downloadDirectory.appending(path: "稀缺资源")

        await coordinator.add(links: [link], autoExtract: true, directory: directory)
        let task = try #require(model.tasks.first)
        await ed2k.setSnapshots([snapshot(path: directory.appending(path: "Ubuntu.zip"))])
        await coordinator.poll()
        await coordinator.pause(task.id)
        await coordinator.resume(task.id)
        await coordinator.remove(task.id, deleteFiles: deleteFiles)
        await coordinator.stop()

        #expect(await ed2k.addedLinks == [link])
        #expect(await ed2k.directories == [directory])
        #expect(await http.addedLinks.isEmpty)
        #expect(await ed2k.pausedIDs == ["task-1"])
        #expect(await ed2k.resumedIDs == ["task-1"])
        #expect(await ed2k.deletesFiles == [deleteFiles])
        #expect(model.activeTasks.isEmpty)
        #expect(deleteFiles ? model.tasks.isEmpty : model.tasks.first?.deletedAt != nil)
    }

    @Test("电驴启动失败不影响 HTTP，错误文案不提 aria2")
    func startupFailure() async {
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        let coordinator = DownloadCoordinator(model: model, engines: [FakeEngine(), FakeEngine(kind: .ed2k, startError: .binaryNotFound)])

        await coordinator.start(options: options)

        #expect(model.engineStates[.http] == .running)
        #expect(model.engineStates[.ed2k] == .failed("未找到电驴下载工具"))
        await coordinator.stop()
    }

    @Test("重启历史由相同 hash 的快照接管，保持记录身份和自动解压设置")
    func historyRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "Ed2kHistory-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var task = DownloadTask(link: link, autoExtract: true)
        task.engineTaskID = hash
        task.status = .waitingForSources
        try TaskHistoryStore(directory: directory).flush(tasks: [task])
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        model.loadTaskHistory(from: TaskHistoryStore(directory: directory))
        let ed2k = FakeEngine(kind: .ed2k)
        await ed2k.setSnapshots([snapshot(id: hash)])
        let coordinator = DownloadCoordinator(model: model, engines: [ed2k])

        await coordinator.start(options: options)
        await coordinator.poll()

        #expect(model.tasks.count == 1)
        #expect(model.tasks.first?.id == task.id)
        #expect(model.tasks.first?.receivedBytes == 40)
        #expect(model.tasks.first?.detail == .ed2k(hash: hash, longTail: longTail))
        #expect(model.tasks.first?.postDownload.autoExtract == true)
        await coordinator.stop()
        model.flushTaskHistory()
    }

    @Test("已完成电驴记录删除会通知引擎，防止重启重新导入", arguments: [false, true])
    func completedRemoval(deleteFiles: Bool) async throws {
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        let ed2k = FakeEngine(kind: .ed2k)
        await ed2k.setSnapshots([snapshot(status: .completed)])
        let coordinator = DownloadCoordinator(model: model, engines: [ed2k])
        await coordinator.start(options: options)
        await coordinator.poll()
        let task = try #require(model.tasks.first)

        await coordinator.remove(task.id, deleteFiles: deleteFiles)
        await coordinator.poll()

        #expect(model.activeTasks.isEmpty)
        #expect(deleteFiles ? model.tasks.isEmpty : model.tasks.first?.deletedAt != nil)
        #expect(await ed2k.removedIDs == ["task-1"])
        #expect(await ed2k.deletesFiles == [deleteFiles])
        await coordinator.stop()
    }

    @Test("清理完成任务也会清理电驴引擎记录，保留已下载文件")
    func clearCompleted() async throws {
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        let ed2k = FakeEngine(kind: .ed2k)
        await ed2k.setSnapshots([snapshot(status: .completed)])
        let coordinator = DownloadCoordinator(model: model, engines: [ed2k])
        await coordinator.start(options: options)
        await coordinator.poll()

        model.clearCompletedTasks()
        for _ in 0..<100 {
            if model.activeTasks.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await coordinator.poll()

        #expect(model.activeTasks.isEmpty)
        #expect(model.tasks.first?.deletedAt != nil)
        #expect(await ed2k.removedIDs == ["task-1"])
        #expect(await ed2k.deletesFiles == [false])
        await coordinator.stop()
    }

    @Test("电驴完成的压缩包使用快照 savePath 触发自动解压")
    func completedArchiveExtraction() async throws {
        let context = try ExtractionTestContext()
        let path = context.root.appending(path: "Ubuntu.zip")
        try Data("压缩包测试".utf8).write(to: path)
        let ed2k = FakeEngine(kind: .ed2k)
        let coordinator = DownloadCoordinator(model: context.model, engines: [ed2k])
        context.coordinator.start()
        await coordinator.start(options: EngineOptions(downloadDirectory: context.root))
        await coordinator.add(links: [link], autoExtract: true)

        await ed2k.setSnapshots([snapshot(status: .completed, path: path)])
        await coordinator.poll()
        try await context.waitUntil { await context.extractor.calls.count == 1 }

        #expect(await context.extractor.calls.first?.archive == path)
        #expect(context.model.tasks.first?.savePath == path)
        await coordinator.stop()
        try await context.clean()
    }
}
