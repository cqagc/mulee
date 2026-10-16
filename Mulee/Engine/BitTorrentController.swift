import Foundation
import MuleeCore
import Observation

/// BT 的设置与会话监测。文件列表由选中任务的详情视图独立按需读取。
@Observable
final class BitTorrentController {
    let engine: TorrentEngine
    let watchFolders = TorrentWatchFolderService()
    private var watchedDrafts = Set<String>()
    private var submittedWatchedDrafts = Set<String>()
    private weak var model: AppModel?
    private var configuration: TorrentEngineSettings
    private var isRunning = false
    private var monitor: Task<Void, Never>?
    private var configurationTask: Task<Void, Never>?
    private var reachability = BitTorrentPortReachability()
    private var listenPort: Int?
    private var ed2kPortMappings: ExtraPortMappings?
    private var mappingTask: Task<Void, Never>?
    var issue: String?

    init(engine: TorrentEngine, model: AppModel, configuration: TorrentEngineSettings) {
        self.engine = engine
        self.model = model
        self.configuration = configuration
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        reachability = BitTorrentPortReachability()
        configure(configuration)
        if let settings = model?.downloadSettings {
            watchFolders.start(settings: settings) { [weak self] _, text, autoStart in
                guard let self else { return false }
                return try await self.acceptWatchedFile(text: text, autoStart: autoStart)
            }
        }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshSession()
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
        }
    }

    func stop() {
        isRunning = false
        watchFolders.stop()
        model?.publicTrackers?.stop()
        monitor?.cancel()
        monitor = nil
        configurationTask?.cancel()
        model?.networkStatus.bittorrentPortReachable = nil
        model?.networkStatus.portMappingSucceeded = nil
        model?.ed2k?.clearPortMappings()
    }

    func configure(_ configuration: TorrentEngineSettings) {
        if self.configuration.listenPort != configuration.listenPort {
            reachability = BitTorrentPortReachability()
            model?.networkStatus.bittorrentPortReachable = nil
        }
        if !configuration.portMapping {
            model?.networkStatus.portMappingSucceeded = nil
            model?.ed2k?.clearPortMappings()
        }
        self.configuration = configuration
        guard isRunning else { return }
        let previous = configurationTask
        configurationTask = Task { [weak self] in
            await previous?.value
            guard let self, self.isRunning, !Task.isCancelled else { return }
            do {
                try await self.engine.configure(configuration)
                self.issue = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.issue = EngineStatusPresentation.errorMessage(error)
            }
        }
    }

    func setEd2kPortMappings(_ mappings: ExtraPortMappings) {
        guard mappings != ed2kPortMappings else { return }
        ed2kPortMappings = mappings
        let previous = mappingTask
        mappingTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do { try await self.engine.setExtraPortMappings(mappings) } catch {
                if self.ed2kPortMappings == mappings { self.ed2kPortMappings = nil }
                self.issue = EngineStatusPresentation.errorMessage(error)
            }
        }
    }

    func observePeers(in tasks: [DownloadTask]) {
        reachability.observePeers(tasks.contains { task in
            if case .bittorrent(_, _, let peers, _) = task.detail { return peers > 0 }
            return false
        })
    }

    func confirmWatchedDrafts(_ links: [ParsedLink]) {
        submittedWatchedDrafts.formUnion(links.map(\.original).filter { watchedDrafts.contains($0) })
    }

    func refreshTaskLocation(_ id: String) async {
        guard let snapshots = try? await engine.snapshots(),
              let snapshot = snapshots.first(where: { $0.engineTaskID == id }),
              let model, let index = model.tasks.firstIndex(where: { $0.kind == .bittorrent && $0.engineTaskID == id }) else { return }
        // 旧书签会阻止普通快照更新路径；主动移动或重命名后要重新绑定实际位置。
        model.tasks[index].fileBookmark = nil
        model.tasks[index].fileMissing = nil
        model.tasks[index].savePath = snapshot.savePath
        model.tasks[index].writeDirectories = snapshot.writeDirectories
        model.tasks[index].name = snapshot.name
        if [.completed, .seeding].contains(snapshot.status) { FileTracker.capture(&model.tasks[index]) }
    }

    private func acceptWatchedFile(text: String, autoStart: Bool) async throws -> Bool {
        guard let model, let settings = model.downloadSettings else { return false }
        let draft = NewTaskModel(inputText: text, saveDirectory: URL(filePath: settings.saveDirectory), autoExtract: settings.autoExtract)
        guard draft.canStartDownload else {
            throw EngineError.rpc(code: 3, message: String(localized: "种子文件或磁力链接无效，请检查内容后重试。"))
        }
        let previousIDs = Set(model.tasks.map(\.id))
        let sources = Set(draft.downloadLinks.map(\.original))
        if autoStart {
            guard await draft.checkBeforeAdding(in: model, settings: settings), let coordinator = model.coordinator else {
                throw EngineError.rpc(code: 3, message: String(localized: "需要确认下载选项，请关闭自动开始后重新扫描。"))
            }
            await coordinator.add(
                links: draft.downloadLinks, autoExtract: settings.autoExtract, directory: draft.saveDirectory,
                filePriorities: draft.filePriorities, torrentDownloadModes: draft.torrentDownloadModes
            )
        } else {
            // 不抢占用户已打开的草稿；监视到的多个文件按顺序逐个确认。
            while model.isShowingNewTask {
                try await Task.sleep(for: .milliseconds(100))
            }
            watchedDrafts.formUnion(sources)
            defer {
                watchedDrafts.subtract(sources)
                submittedWatchedDrafts.subtract(sources)
            }
            model.showNewTask(prefill: text)
            while model.isShowingNewTask {
                try await Task.sleep(for: .milliseconds(100))
            }
            guard !submittedWatchedDrafts.isDisjoint(with: sources) else { return false }
            // 新建面板先关闭、异步添加随后才完成；只按引擎确认的结果归档。
            for _ in 0..<3100 {
                if model.tasks.contains(where: { !previousIDs.contains($0.id) && sources.contains($0.sourceLink) }) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        guard let task = model.tasks.first(where: { !previousIDs.contains($0.id) && sources.contains($0.sourceLink) }),
              task.engineTaskID != nil, task.status != .failed else {
            throw EngineError.rpc(code: 3, message: String(localized: "添加未完成，原文件已保留。请检查下载引擎后重新扫描。"))
        }
        return true
    }

    func refreshSession() async {
        guard isRunning else { return }
        do {
            let status = try await engine.sessionStatus()
            let removed = await engine.consumePolicyRemovals()
            if !removed.isEmpty, let model {
                let removedTaskIDs = Set(model.tasks.filter {
                    $0.kind == .bittorrent && $0.engineTaskID.map { removed.contains($0) } == true
                }.map(\.id))
                model.tasks.removeAll { removedTaskIDs.contains($0.id) }
                if let selected = model.selectedTaskID, removedTaskIDs.contains(selected) {
                    model.selectedTaskID = nil
                }
            }
            guard isRunning, !Task.isCancelled else { return }
            if (listenPort != nil && listenPort != status.listenPort)
                || (reachability.sawIncoming && !status.hasIncomingConnections) {
                // 入站历史由 torrentd 在会话内累计；从有变无表示会话已经重启。
                reachability = BitTorrentPortReachability()
            }
            listenPort = status.listenPort
            model?.networkStatus.bittorrentPortReachable = reachability.observe(incoming: status.hasIncomingConnections)
            if status.portMappingEnabled == true {
                let results = status.portMappings ?? []
                model?.networkStatus.portMappingSucceeded = ["tcp", "udp"].allSatisfy { proto in
                    results.contains { $0.protocol == proto && $0.usesRequestedPort }
                } ? true : results.isEmpty ? nil : false
            } else {
                model?.networkStatus.portMappingSucceeded = nil
            }
            await model?.ed2k?.updatePortMappings(status)
            issue = nil
        } catch {
            guard isRunning, !Task.isCancelled else { return }
            reachability = BitTorrentPortReachability()
            listenPort = nil
            model?.networkStatus.bittorrentPortReachable = nil
            model?.networkStatus.portMappingSucceeded = nil
            model?.ed2k?.clearPortMappings()
            issue = EngineStatusPresentation.errorMessage(error)
        }
    }
}
