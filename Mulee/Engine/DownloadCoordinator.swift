import Foundation
import MuleeCore

/// 把引擎的异步操作与主线程上的 UI 状态连接起来。
@MainActor
final class DownloadCoordinator {
    private let model: AppModel
    private var engines: [any DownloadEngine]
    private let videoBootstrap: VideoEngineBootstrap?
    private let videoEngineFactory: (@MainActor (VideoEngineConfiguration) async throws -> any DownloadEngine)?
    private var waitingVideoLinks: [DownloadTask.ID: (link: ParsedLink, directory: URL?)] = [:]
    private var submittingVideoIDs: Set<DownloadTask.ID> = []
    private var videoFFmpegURL: URL?
    private var videoStartupTask: Task<Void, Never>?
    private var videoConfigurationTask: Task<Void, Never>?
    private var videoConfiguration = VideoEngineConfiguration()
    private var started: Set<TaskKind> = []
    private var generation: UUID?
    private var pollingTask: Task<Void, Never>?
    private var applyTask: Task<Void, Never>?
    private var latestOptions: EngineOptions?
    private var pendingAdds: [TaskKind: Int] = [:]
    private var revisions: [TaskKind: Int] = [:]
    private var excludedTaskIDs: [TaskKind: Set<String>] = [:]
    private var isPolling = false

    init(
        model: AppModel, engines: [any DownloadEngine], videoBootstrap: VideoEngineBootstrap? = nil,
        videoEngineFactory: (@MainActor (VideoEngineConfiguration) async throws -> any DownloadEngine)? = nil
    ) {
        self.model = model
        self.engines = engines
        self.videoBootstrap = videoBootstrap
        self.videoEngineFactory = videoEngineFactory
        model.coordinator = self
    }

    func start(options: EngineOptions, videoConfiguration: VideoEngineConfiguration = VideoEngineConfiguration()) async {
        guard generation == nil, !Task.isCancelled else { return }
        let token = UUID()
        generation = token
        latestOptions = options
        self.videoConfiguration = videoConfiguration
        // 尚未交给引擎的任务没有会话及可靠的目录记录，重启后明确提示重新下载。
        for index in model.tasks.indices where model.tasks[index].kind == .video
            && model.tasks[index].engineTaskID == nil
            && [.queued, .paused].contains(model.tasks[index].status) {
            model.tasks[index].status = .failed
            model.tasks[index].errorMessage = "上次退出时视频工具尚未准备好，可以重新下载"
        }
        if videoBootstrap != nil || videoEngineFactory != nil {
            model.engineStates[.video] = .preparing
            videoStartupTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let engine: any DownloadEngine
                    if let factory = self.videoEngineFactory {
                        engine = try await factory(videoConfiguration)
                    } else if let videoBootstrap = self.videoBootstrap {
                        engine = try await videoBootstrap.makeEngine(configuration: videoConfiguration)
                        // 没有 ffmpeg 时引擎照常启动：单文件格式仍能下载，只是不能合并音视频。
                        self.videoFFmpegURL = await videoBootstrap.ffmpegURL
                    } else {
                        return
                    }
                    guard self.generation == token, !Task.isCancelled else { return }
                    // 准备期间设置可能变化；启动前下发最新值。
                    if let video = engine as? YtDlpEngine {
                        try await self.videoConfiguration.apply(to: video)
                    }
                    try await engine.start(options: self.latestOptions ?? options)
                    guard self.generation == token, !Task.isCancelled else {
                        await engine.stop()
                        return
                    }
                    self.engines.append(engine)
                    self.started.insert(.video)
                    self.model.engineStates[.video] = self.videoBootstrap == nil ? .running : EngineStatusPresentation.videoReadyState(ffmpegURL: self.videoFFmpegURL)
                    self.configureVideo(self.videoConfiguration)
                    await self.submitWaitingVideos()
                } catch {
                    guard self.generation == token, !Task.isCancelled else { return }
                    let reason = EngineStatusPresentation.errorMessage(error)
                    self.model.engineStates[.video] = .failed(reason)
                    self.failWaitingVideos(reason: reason)
                }
            }
        }
        await withTaskGroup(of: (TaskKind, String?).self) { group in
            for engine in engines {
                group.addTask {
                    do {
                        try await engine.start(options: options)
                        return (engine.kind, nil)
                    } catch {
                        return (engine.kind, EngineStatusPresentation.errorMessage(error, kind: engine.kind))
                    }
                }
            }
            for await (kind, error) in group {
                guard generation == token else { continue }
                if let error {
                    model.engineStates[kind] = .failed(error)
                } else {
                    started.insert(kind)
                    model.engineStates[kind] = .running
                    if kind == .bittorrent { model.bitTorrent?.start() }
                }
            }
        }
        guard generation == token else {
            // stop 可能发生在 start 等待就绪期间，清理迟到的启动结果。
            await stopEngines()
            return
        }
        if Task.isCancelled {
            await stop()
            return
        }
        if let latestOptions, latestOptions != options {
            apply(options: latestOptions)
        }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard let self else { return }
                await self.poll()
            }
        }
    }

    func stop() async {
        generation = nil
        model.bitTorrent?.stop()
        waitingVideoLinks.removeAll()
        pollingTask?.cancel()
        pollingTask = nil
        applyTask?.cancel()
        applyTask = nil
        videoStartupTask?.cancel()
        videoConfigurationTask?.cancel()
        started.removeAll()
        for kind in TaskKind.allCases {
            model.engineStates[kind] = .unavailable
        }
        await stopEngines()
        await videoStartupTask?.value
        videoStartupTask = nil
    }

    func poll() async {
        guard let token = generation, !isPolling else { return }
        isPolling = true
        defer { isPolling = false }
        var snapshots: [TaskKind: [EngineTaskSnapshot]] = [:]
        var snapshotRevisions: [TaskKind: Int] = [:]
        for engine in engines where started.contains(engine.kind) {
            // 添加期间的快照可能尚不含新 GID，不能据此删除刚插入的任务。
            guard pendingAdds[engine.kind, default: 0] == 0 else { continue }
            let revision = revisions[engine.kind, default: 0]
            do {
                let current = try await engine.snapshots()
                guard generation == token else { return }
                if pendingAdds[engine.kind, default: 0] == 0, revisions[engine.kind, default: 0] == revision {
                    snapshots[engine.kind] = current
                    snapshotRevisions[engine.kind] = revision
                }
            } catch {
                guard generation == token else { return }
                model.engineStates[engine.kind] = .failed(EngineStatusPresentation.errorMessage(error))
            }
        }
        guard generation == token else { return }
        snapshots = snapshots.filter { kind, _ in
            pendingAdds[kind, default: 0] == 0 && revisions[kind, default: 0] == snapshotRevisions[kind]
        }
        for kind in snapshots.keys {
            snapshots[kind]?.removeAll { excludedTaskIDs[kind, default: []].contains($0.engineTaskID) }
        }
        model.tasks = EngineSnapshotMerger.merge(
            tasks: model.tasks, snapshots: snapshots, now: .now, videoConfiguration: videoConfiguration
        )
        if let selected = model.selectedTaskID, !model.tasks.contains(where: { $0.id == selected }) {
            model.selectedTaskID = nil
        }
        model.bitTorrent?.observePeers(in: model.tasks)
        model.downloadRateHistory = EngineSnapshotMerger.appendingRate(model.totalDownloadRate, to: model.downloadRateHistory)
    }

    func add(
        links: [ParsedLink], autoExtract: Bool, directory: URL? = nil,
        filePriorities: [ParsedLink: [Int]] = [:]
    ) async {
        var insertionIndex = 0
        for link in links {
            var task = DownloadTask(link: link, autoExtract: autoExtract)
            if let detail = videoConfiguration.detail(for: link) {
                task.detail = detail
            }
            if link.kind == .video, videoBootstrap != nil || videoEngineFactory != nil || engine(for: .video) != nil {
                task.status = .queued
                model.tasks.insert(task, at: min(insertionIndex, model.tasks.count))
                if insertionIndex == 0 { model.selectedTaskID = task.id }
                insertionIndex += 1
                waitingVideoLinks[task.id] = (link, directory)
                if engine(for: .video) != nil {
                    await submitWaitingVideos()
                } else if case .failed(let reason) = model.engineStates[.video] {
                    failWaitingVideos(reason: reason)
                }
                continue
            }
            task.status = .engineUnavailable
            if let engine = engine(for: link.kind) {
                pendingAdds[link.kind, default: 0] += 1
                do {
                    if let torrent = engine as? TorrentEngine {
                        task.engineTaskID = try await torrent.add(
                            link: link, directory: directory, filePriorities: filePriorities[link]
                        )
                    } else {
                        task.engineTaskID = try await engine.add(link: link, directory: directory)
                    }
                    task.status = .queued
                } catch {
                    task.status = .failed
                    task.errorMessage = EngineStatusPresentation.errorMessage(error)
                }
                pendingAdds[link.kind, default: 0] -= 1
                revisions[link.kind, default: 0] += 1
            } else if engines.contains(where: { $0.kind == link.kind }) || (link.kind == .video && videoBootstrap != nil) {
                task.status = .failed
                if case .failed(let reason) = model.engineStates[link.kind] {
                    task.errorMessage = reason
                } else {
                    task.errorMessage = "下载引擎未运行"
                }
            }
            if task.kind == .http {
                task.detail = .http(connections: 0)
            }
            model.tasks.insert(task, at: min(insertionIndex, model.tasks.count))
            if insertionIndex == 0 {
                model.selectedTaskID = task.id
            }
            insertionIndex += 1
        }
    }

    func pause(_ id: DownloadTask.ID) async {
        await perform(id, action: .pause)
    }

    func resume(_ id: DownloadTask.ID) async {
        await perform(id, action: .resume)
    }

    func remove(_ id: DownloadTask.ID, deleteFiles: Bool = false) async {
        guard let index = model.tasks.firstIndex(where: { $0.id == id }) else { return }
        let task = model.tasks[index]
        waitingVideoLinks[id] = nil
        if (task.status == .completed && task.kind != .bittorrent) || task.engineTaskID == nil {
            excludeFromSnapshots(task)
            model.removeRecord(id)
            return
        }
        guard let engine = engine(for: task.kind), let engineTaskID = task.engineTaskID else {
            setError("下载引擎未运行", for: id)
            return
        }
        let wasSelected = model.selectedTaskID == id
        excludeFromSnapshots(task)
        model.removeRecord(id)
        revisions[task.kind, default: 0] += 1
        defer { revisions[task.kind, default: 0] += 1 }
        do {
            try await engine.remove(engineTaskID, deleteFiles: deleteFiles)
        } catch {
            excludedTaskIDs[task.kind]?.remove(engineTaskID)
            var restored = task
            restored.errorMessage = EngineStatusPresentation.errorMessage(error)
            model.tasks.insert(restored, at: min(index, model.tasks.count))
            if wasSelected {
                model.selectedTaskID = id
            }
        }
    }

    /// 已删除的记录不再从仍在返回旧结果的引擎中重新导入。
    func excludeFromSnapshots(_ task: DownloadTask) {
        guard let id = task.engineTaskID else { return }
        excludedTaskIDs[task.kind, default: []].insert(id)
    }

    func apply(options: EngineOptions) {
        latestOptions = options
        applyTask?.cancel()
        applyTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(0.5))
            } catch {
                return
            }
            guard let self, let token = self.generation else { return }
            for engine in self.engines where self.started.contains(engine.kind) {
                guard !Task.isCancelled, self.generation == token else { return }
                do {
                    try await engine.apply(options: options)
                } catch {
                    guard !Task.isCancelled, self.generation == token else { return }
                    self.model.engineStates[engine.kind] = .failed(EngineStatusPresentation.errorMessage(error))
                }
            }
        }
    }

    func configureVideo(_ configuration: VideoEngineConfiguration) {
        videoConfiguration = configuration
        let previous = videoConfigurationTask
        videoConfigurationTask = Task { [weak self] in
            await previous?.value
            guard let self, let token = self.generation, !Task.isCancelled,
                  let engine = self.engines.first(where: { $0.kind == .video }) as? YtDlpEngine else { return }
            do {
                try await configuration.apply(to: engine)
                guard self.generation == token, !Task.isCancelled else { return }
                self.model.engineStates[.video] = EngineStatusPresentation.videoReadyState(ffmpegURL: self.videoFFmpegURL)
            } catch {
                guard self.generation == token, !Task.isCancelled else { return }
                self.model.engineStates[.video] = .failed(EngineStatusPresentation.errorMessage(error))
            }
        }
    }

    private enum Action {
        case pause
        case resume
    }

    private func perform(_ id: DownloadTask.ID, action: Action) async {
        guard let task = model.tasks.first(where: { $0.id == id }) else { return }
        if let engineTaskID = task.engineTaskID {
            guard let engine = engine(for: task.kind) else {
                setError("下载引擎未运行", for: id)
                return
            }
            do {
                revisions[task.kind, default: 0] += 1
                switch action {
                case .pause: try await engine.pause(engineTaskID)
                case .resume: try await engine.resume(engineTaskID)
                }
                revisions[task.kind, default: 0] += 1
            } catch {
                setError(EngineStatusPresentation.errorMessage(error), for: id)
                return
            }
        }
        guard let index = model.tasks.firstIndex(where: { $0.id == id }) else { return }
        switch action {
        case .pause:
            model.tasks[index].status = .paused
            model.tasks[index].downloadRate = 0
            model.tasks[index].uploadRate = 0
            model.tasks[index].estimatedTimeRemaining = nil
            model.tasks[index].errorMessage = nil
        case .resume:
            model.tasks[index].status = waitingVideoLinks[id] != nil ? .queued
                : task.engineTaskID == nil ? (task.kind == .ed2k ? .waitingForSources : .downloading) : .queued
            model.tasks[index].errorMessage = nil
            if waitingVideoLinks[id] != nil { await submitWaitingVideos() }
        }
    }

    private func failWaitingVideos(reason: String) {
        for index in model.tasks.indices where waitingVideoLinks[model.tasks[index].id] != nil {
            model.tasks[index].status = .failed
            model.tasks[index].errorMessage = reason
        }
        waitingVideoLinks.removeAll()
    }

    private func submitWaitingVideos() async {
        await videoConfigurationTask?.value
        guard let token = generation, !Task.isCancelled, let engine = engine(for: .video) else { return }
        for id in model.tasks.map(\.id) {
            guard generation == token, !Task.isCancelled else { return }
            guard let pending = waitingVideoLinks[id], !submittingVideoIDs.contains(id),
                  model.tasks.contains(where: { $0.id == id && $0.status == .queued }) else { continue }
            submittingVideoIDs.insert(id)
            pendingAdds[.video, default: 0] += 1
            defer {
                submittingVideoIDs.remove(id)
                pendingAdds[.video, default: 0] -= 1
                revisions[.video, default: 0] += 1
            }
            do {
                let engineID = try await engine.add(link: pending.link, directory: pending.directory)
                guard generation == token, let index = model.tasks.firstIndex(where: { $0.id == id }) else {
                    excludedTaskIDs[.video, default: []].insert(engineID)
                    try await engine.remove(engineID, deleteFiles: false)
                    continue
                }
                model.tasks[index].engineTaskID = engineID
                waitingVideoLinks[id] = nil
                if model.tasks[index].status == .paused {
                    try await engine.pause(engineID)
                }
            } catch {
                waitingVideoLinks[id] = nil
                guard generation == token, let index = model.tasks.firstIndex(where: { $0.id == id }) else { continue }
                model.tasks[index].status = .failed
                model.tasks[index].errorMessage = EngineStatusPresentation.errorMessage(error)
            }
        }
    }

    private func setError(_ message: String, for id: DownloadTask.ID) {
        guard let index = model.tasks.firstIndex(where: { $0.id == id }) else { return }
        model.tasks[index].errorMessage = message
    }

    private func engine(for kind: TaskKind) -> (any DownloadEngine)? {
        guard started.contains(kind) else { return nil }
        return engines.first { $0.kind == kind }
    }

    private func stopEngines() async {
        await withTaskGroup(of: Void.self) { group in
            for engine in engines {
                group.addTask { await engine.stop() }
            }
        }
    }
}
